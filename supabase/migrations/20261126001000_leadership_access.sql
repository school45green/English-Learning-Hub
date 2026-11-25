create table hub_internal.leadership_accounts (
  role text primary key check (role in ('principal','vice_principal')),
  key_hash bytea
);
alter table hub_internal.leadership_accounts enable row level security;
revoke all on hub_internal.leadership_accounts from public,anon,authenticated;
insert into hub_internal.leadership_accounts(role) values ('principal'),('vice_principal');

create function public.hub_manage_leadership(p_role text,p_action text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare secret text;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise insufficient_privilege; end if;
  if p_action='status' then
    return (select jsonb_object_agg(role,key_hash is not null) from hub_internal.leadership_accounts);
  end if;
  if p_action='issue' then secret:=encode(extensions.gen_random_bytes(24),'hex');
  elsif p_action is distinct from 'disable' then raise exception 'Unknown action'; end if;
  update hub_internal.leadership_accounts set key_hash=extensions.digest(secret,'sha256') where role=p_role;
  if not found then raise exception 'Unknown account'; end if;
  return jsonb_build_object('key',secret);
end $$;
revoke all on function public.hub_manage_leadership(text,text) from public,anon,authenticated;
grant execute on function public.hub_manage_leadership(text,text) to authenticated;

create function public.hub_leadership_report(p_role text,p_key text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if p_key is null or p_key !~ '^[a-f0-9]{48}$' or not exists(
    select 1 from hub_internal.leadership_accounts where role=p_role and key_hash=extensions.digest(p_key,'sha256')
  ) then raise insufficient_privilege; end if;
  return (
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
  );
end $$;
revoke all on function public.hub_leadership_report(text,text) from public,anon,authenticated;
grant execute on function public.hub_leadership_report(text,text) to anon,authenticated;
