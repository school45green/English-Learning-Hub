create function public.hub_resolve_student_resource(p_token text,p_group text,p_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_student uuid; v_path text;
begin
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' or p_id is null then return null; end if;
 select q.student_id into v_student from hub_internal.student_sessions q
 join hub_internal.student_codes c on c.student_id=q.student_id and c.invite_hash=q.credential_hash
 join public.students s on s.id=q.student_id and s.active
 where q.token_hash=extensions.digest(p_token,'sha256') and q.expires_at>now() and c.expires_at>now();
 if v_student is null then return null; end if;
 if p_group='units' and exists(select 1 from public.activities a where a.id=p_id and a.published and hub_internal.activity_assigned(v_student,a.id)) then
  v_path:='units/'||p_id||'/resource';
 elsif p_group='honors' and exists(select 1 from public.honors h where h.id=p_id and h.student_id=v_student and h.archived_at is null) then
  v_path:='honors/'||p_id||'/resource';
 end if;
 if exists(select 1 from storage.objects where bucket_id='hub-private' and name=v_path) then return v_path; end if;
 return null;
end $$;
revoke all on function public.hub_resolve_student_resource(text,text,uuid) from public,anon,authenticated;
grant execute on function public.hub_resolve_student_resource(text,text,uuid) to service_role;
