alter table hub_internal.leadership_accounts
  add column invite_hash bytea, add column invite_until timestamptz,
  add column session_hash bytea, add column session_until timestamptz;

create function hub_internal.leadership_data() returns jsonb
language sql stable set search_path='' as $$
    with roster as (
      select s.id,s.full_name,c.id class_id,c.name class_name from public.students s
      join public.school_classes c on c.id=s.class_id where c.archived_at is null and s.active
    ), totals as (
      select c.name,c.course,(select count(*) from roster where class_id=c.id) students,
        (select count(*) from public.submissions r join roster s on s.id=r.student_id where s.class_id=c.id) submissions,
        (select count(*) from public.hub_plans p join roster s on s.id=p.student_id where s.class_id=c.id and p.completed) completed
      from public.school_classes c where c.archived_at is null order by c.name
    ), results as (
      select s.full_name,s.class_name,a.title,r.score,a.max_score from public.submissions r join roster s on s.id=r.student_id
      join public.activities a on a.id=r.activity_id where r.status in ('reviewed','returned') and r.score is not null order by r.submitted_at desc
    ), plans as (
      select s.full_name,s.class_name,p.title,p.kind,p.completed from public.hub_plans p join roster s on s.id=p.student_id order by s.class_name,s.full_name
    ), achievements as (
      select s.full_name,s.class_name,h.title,h.week_start from public.honors h join roster s on s.id=h.student_id order by h.week_start desc
    ) select jsonb_build_object('classes',coalesce((select jsonb_agg(t) from totals t),'[]'),
      'results',coalesce((select jsonb_agg(t) from results t),'[]'),'plans',coalesce((select jsonb_agg(t) from plans t),'[]'),
      'honors',coalesce((select jsonb_agg(t) from achievements t),'[]'))
$$;
revoke all on function hub_internal.leadership_data() from public,anon,authenticated;

create or replace function public.hub_leadership_report(p_role text,p_key text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if p_key is null or p_key !~ '^[a-f0-9]{48}$' or not exists(
    select 1 from hub_internal.leadership_accounts where role=p_role and key_hash=extensions.digest(p_key,'sha256')
  ) then raise insufficient_privilege; end if;
  return hub_internal.leadership_data();
end $$;

create function public.hub_leadership_link(p_role text,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare secret text;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise insufficient_privilege; end if;
  if p_action='status' then return (select jsonb_object_agg(role,case
    when session_until>now() then 'active' when invite_until>now() then 'pending' else 'inactive' end)
    from hub_internal.leadership_accounts); end if;
  if p_action in ('issue','renew') then secret:=encode(extensions.gen_random_bytes(32),'hex');
  elsif p_action is distinct from 'disable' then raise exception 'Unknown action'; end if;
  update hub_internal.leadership_accounts set invite_hash=extensions.digest(secret,'sha256'),
    invite_until=case when secret is not null then now()+interval '24 hours' end,
    key_hash=null,session_hash=null,session_until=null where role=p_role;
  if not found then raise exception 'Unknown role'; end if;
  return jsonb_build_object('link',secret);
end $$;
revoke all on function public.hub_leadership_link(text,text) from public,anon,authenticated;
grant execute on function public.hub_leadership_link(text,text) to authenticated;

create function public.hub_redeem_leadership(p_invite text) returns text
language plpgsql security definer set search_path='' as $$
declare token text:=encode(extensions.gen_random_bytes(32),'hex');
begin
  update hub_internal.leadership_accounts set invite_hash=null,invite_until=null,
    session_hash=extensions.digest(token,'sha256'),session_until=now()+interval '8 hours'
    where invite_hash=extensions.digest(p_invite,'sha256') and invite_until>now();
  if not found then raise insufficient_privilege; end if;
  return token;
end $$;

create function public.hub_leadership_session(p_token text,p_logout boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare account text;
begin
  if p_logout then
    update hub_internal.leadership_accounts set session_hash=null,session_until=null
      where session_hash=extensions.digest(p_token,'sha256');
    return null;
  end if;
  select role into account from hub_internal.leadership_accounts where
    session_hash=extensions.digest(p_token,'sha256') and session_until>now();
  if not found then raise insufficient_privilege; end if;
  return jsonb_build_object('role',account,'report',hub_internal.leadership_data());
end $$;
revoke all on function public.hub_redeem_leadership(text),public.hub_leadership_session(text,boolean) from public;
grant execute on function public.hub_redeem_leadership(text),public.hub_leadership_session(text,boolean) to anon,authenticated;
