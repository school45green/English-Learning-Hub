
create table hub_internal.student_sessions (
 student_id uuid primary key references public.students(id),
 token_hash bytea not null unique,
 credential_hash bytea not null,
 expires_at timestamptz not null
);
alter table hub_internal.student_sessions enable row level security;

create function public.hub_login_classes()
returns table(id uuid,name text,grade_level text) language sql stable security definer set search_path='' as $$
select c.id,c.name,c.grade_level from public.school_classes c
where c.name not like '%تجريبي%'
order by c.grade_level,c.name
$$;

create function public.hub_student_sign_in(p_class uuid,p_name text,p_pin text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cred hub_internal.student_codes%rowtype; token text;
begin
 if p_class is null or p_name is null or length(p_name)>200 or p_pin is null or p_pin !~ '^[0-9]{4}$' then return null; end if;
 select c.* into cred from hub_internal.student_codes c join public.students s on s.id=c.student_id
 where s.class_id=p_class and s.full_name=regexp_replace(btrim(p_name),'[[:space:]]+',' ','g')
 and s.active and c.expires_at>now() for update of c;
 if not found then return null; end if;
 if cred.window_since is null or cred.window_since<=now()-interval '30 minutes' then
   cred.window_since:=now(); cred.failures:=0;
 end if;
 if cred.failures>=5 then return null; end if;
 if extensions.crypt(p_pin,cred.pin_hash) is distinct from cred.pin_hash then
   update hub_internal.student_codes set failures=cred.failures+1,window_since=cred.window_since where student_id=cred.student_id;
   return null;
 end if;
 token:=encode(extensions.gen_random_bytes(32),'hex');
 insert into hub_internal.student_sessions(student_id,token_hash,credential_hash,expires_at)
 values(cred.student_id,extensions.digest(token,'sha256'),cred.invite_hash,now()+interval '2 hours')
 on conflict(student_id) do update set token_hash=excluded.token_hash,credential_hash=excluded.credential_hash,expires_at=excluded.expires_at;
 return jsonb_build_object('token',token,'dashboard',hub_internal.student_dashboard(cred.student_id));
end $$;

create function public.hub_student_session(p_token text,p_activity uuid default null,p_answers jsonb default null,p_logout boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_student uuid; v_hash bytea;
begin
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return null; end if;
 v_hash:=extensions.digest(p_token,'sha256');
 if p_logout then
   delete from hub_internal.student_sessions where token_hash=v_hash;
   return null;
 end if;
 select q.student_id into v_student from hub_internal.student_sessions q
 join hub_internal.student_codes c on c.student_id=q.student_id and c.invite_hash=q.credential_hash
 join public.students s on s.id=q.student_id and s.active
 where q.token_hash=v_hash and q.expires_at>now() and c.expires_at>now();
 if not found then return null; end if;
 if p_activity is not null then return hub_internal.student_submit_quiz(v_student,p_activity,p_answers); end if;
 return hub_internal.student_dashboard(v_student);
end $$;

create function public.hub_issue_class_codes(p_class uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare st record; codes jsonb:='[]'; issued jsonb;
begin
 if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
 perform pg_advisory_xact_lock(hashtext(p_class::text));
 for st in select s.id,s.full_name from public.students s left join hub_internal.student_codes c on c.student_id=s.id
   where s.class_id=p_class and s.active and (c.student_id is null or c.expires_at<=now()) order by s.full_name loop
   issued:=public.hub_issue_student_code(st.id);
   codes:=codes||jsonb_build_array(jsonb_build_object('name',st.full_name,'pin',issued->>'pin'));
 end loop;
 return codes;
end $$;

revoke all on function public.hub_login_classes(),public.hub_student_sign_in(uuid,text,text),
 public.hub_student_session(text,uuid,jsonb,boolean),public.hub_issue_class_codes(uuid)
 from public,anon,authenticated;
revoke execute on function public.hub_student_code(text,text,uuid,jsonb) from anon,authenticated;
grant execute on function public.hub_login_classes(),public.hub_student_sign_in(uuid,text,text),
 public.hub_student_session(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.hub_issue_class_codes(uuid) to authenticated;
