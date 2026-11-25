alter function public.hub_issue_class_codes(uuid) set schema hub_internal;
alter function public.hub_issue_class_family(uuid) set schema hub_internal;
revoke all on function hub_internal.hub_issue_class_codes(uuid), hub_internal.hub_issue_class_family(uuid) from public, anon, authenticated;

create function hub_internal.staged_class_credentials(p_class uuid, p_family boolean)
returns jsonb language sql security invoker set search_path='' as $$
  select coalesce(jsonb_agg(item.value order by s.full_name),'[]'::jsonb)
  from vault.decrypted_secrets v
  cross join lateral jsonb_array_elements(v.decrypted_secret::jsonb) item
  join public.students s on s.class_id=p_class and s.active and s.full_name=item.value->>'name'
  left join hub_internal.student_codes code on code.student_id=s.id and code.expires_at>now()
  left join public.parent_access family on family.student_id=s.id and family.revoked_at is null and family.expires_at>now()
  where v.name=(case when p_family then 'hub_family_release:' else 'hub_student_release:' end)||p_class::text
    and v.created_at>now()-interval '30 days'
    and case when p_family
      then extensions.digest(item.value->>'invite','sha256')=family.invite_hash
           and extensions.crypt(item.value->>'pin',family.code_hash)=family.code_hash
      else extensions.crypt(item.value->>'pin',code.pin_hash)=code.pin_hash
    end
$$;
revoke all on function hub_internal.staged_class_credentials(uuid,boolean) from public,anon,authenticated;

create function public.hub_issue_class_codes(p_class uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare staged jsonb; fresh jsonb;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  staged:=hub_internal.staged_class_credentials(p_class,false);
  fresh:=hub_internal.hub_issue_class_codes(p_class);
  return staged||fresh;
end $$;

create function public.hub_issue_class_family(p_class uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare staged jsonb; fresh jsonb;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  staged:=hub_internal.staged_class_credentials(p_class,true);
  fresh:=hub_internal.hub_issue_class_family(p_class);
  return staged||fresh;
end $$;

revoke all on function public.hub_issue_class_codes(uuid), public.hub_issue_class_family(uuid) from public,anon,authenticated;
grant execute on function public.hub_issue_class_codes(uuid), public.hub_issue_class_family(uuid) to authenticated;
