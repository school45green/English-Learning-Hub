alter table hub_internal.leadership_accounts add column standing_secret uuid, add column standing_hash bytea;
create table hub_internal.lead_sessions(
  token_hash bytea primary key, role text not null references hub_internal.leadership_accounts(role),
  valid_until timestamptz not null
);
alter table hub_internal.lead_sessions enable row level security;
revoke all on hub_internal.lead_sessions from public,anon,authenticated;

do $$
declare account text; secret text;
begin
  for account in select role from hub_internal.leadership_accounts loop
    secret:=encode(extensions.gen_random_bytes(32),'hex');
    update hub_internal.leadership_accounts set standing_secret=vault.create_secret(secret),
      standing_hash=extensions.digest(secret,'sha256') where role=account;
  end loop;
end $$;

create function public.hub_standing_link(p_role text,p_action text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare acct hub_internal.leadership_accounts%rowtype; secret text;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise insufficient_privilege; end if;
  if p_action='status' then return (select jsonb_object_agg(role,case when standing_hash is null then 'inactive' else 'active' end) from hub_internal.leadership_accounts); end if;
  select * into strict acct from hub_internal.leadership_accounts where role=p_role for update;
  if p_action='disable' then
    update hub_internal.leadership_accounts set standing_hash=null,session_hash=null,key_hash=null,invite_hash=null where role=p_role;
    delete from hub_internal.lead_sessions where role=p_role;
  elsif p_action in ('issue','enable') then
    if acct.standing_hash is null then
      if p_action='issue' then raise exception 'الرابط ملغى. اختاري تفعيل رابط جديد.'; end if;
      secret:=encode(extensions.gen_random_bytes(32),'hex');
      perform vault.update_secret(acct.standing_secret,secret);
      update hub_internal.leadership_accounts set standing_hash=extensions.digest(secret,'sha256') where role=p_role;
    else
      select decrypted_secret into strict secret from vault.decrypted_secrets where id=acct.standing_secret;
    end if;
  else raise exception 'Unknown action'; end if;
  return jsonb_build_object('link',secret);
end $$;

create function public.hub_open_standing_link(p_invite text) returns text
language plpgsql security definer set search_path='' as $$
declare account text; token text;
begin
  select role into account from hub_internal.leadership_accounts where standing_hash=extensions.digest(p_invite,'sha256') for update;
  if not found then raise insufficient_privilege; end if;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  delete from hub_internal.lead_sessions where role=account and valid_until<=now();
  insert into hub_internal.lead_sessions values(extensions.digest(token,'sha256'),account,now()+interval '8 hours');
  return token;
end $$;
revoke all on function public.hub_open_standing_link(text), public.hub_standing_link(text,text) from public,anon,authenticated;
grant execute on function public.hub_open_standing_link(text) to anon,authenticated;
grant execute on function public.hub_standing_link(text,text) to authenticated;

create or replace function public.hub_leadership_session(p_token text,p_logout boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare account text;
begin
  if p_logout then
    delete from hub_internal.lead_sessions where token_hash=extensions.digest(p_token,'sha256');
    update hub_internal.leadership_accounts set session_hash=null,session_until=null
      where session_hash=extensions.digest(p_token,'sha256');
    return null;
  end if;
  select role into account from hub_internal.lead_sessions where token_hash=extensions.digest(p_token,'sha256') and valid_until>now();
  if found then return jsonb_build_object('role',account,'report',hub_internal.leadership_data()); end if;
  select role into account from hub_internal.leadership_accounts where
    session_hash=extensions.digest(p_token,'sha256') and session_until>now();
  if not found then raise insufficient_privilege; end if;
  return jsonb_build_object('role',account,'report',hub_internal.leadership_data());
end $$;
