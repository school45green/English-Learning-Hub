create schema if not exists hub_internal;
revoke all on schema hub_internal from public,anon,authenticated;
create table hub_internal.student_codes(
 student_id uuid primary key references public.students(id),
 invite_hash bytea not null unique,
 pin_hash text not null,
 expires_at timestamptz not null,
 failures integer not null default 0,
 window_since timestamptz
);
alter table hub_internal.student_codes enable row level security;

create function hub_internal.student_dashboard(v_student uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 if v_student is null then raise exception 'Student account not linked'; end if;
 select jsonb_build_object(
  'student',jsonb_build_object('name',s.full_name,'class_name',c.name,'course',c.course),
  'activities',coalesce((
    select jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'unit',a.unit_no,'kind',a.kind,'skill',a.skill,'resource',exists(select 1 from storage.objects o where o.bucket_id='hub-private' and o.name='units/'||a.id||'/resource'),'max_score',a.max_score,'questions',(
      select coalesce(jsonb_agg(jsonb_build_object('id',q.value->>'id','prompt',q.value->>'prompt','choices',q.value->'choices')),'[]'::jsonb)
      from jsonb_array_elements(coalesce(a.answer_key->'questions','[]'::jsonb)) q
    ),'attempts_used',(select count(*) from public.submissions x where x.student_id=v_student and x.activity_id=a.id),'max_attempts',a.max_attempts))
    from public.activities a join public.activity_targets t on t.activity_id=a.id
    where t.class_id=s.class_id and a.published=true
  ),'[]'::jsonb),
  'plans',coalesce((select jsonb_agg(jsonb_build_object('kind',p.kind,'title',p.title,'instructions',p.instructions,'due_on',p.due_on,'completed',p.completed) order by p.due_on) from public.hub_plans p where p.student_id=v_student),'[]'::jsonb),
  'honors',coalesce((select jsonb_agg(jsonb_build_object('title',h.title,'category',h.category,'week_start',h.week_start,'description',h.description,'id',h.id,'resource',exists(select 1 from storage.objects o where o.bucket_id='hub-private' and o.name='honors/'||h.id||'/resource'))) from public.honors h where h.student_id=v_student),'[]'::jsonb),
  'results',coalesce((
    select jsonb_agg(jsonb_build_object('activity',a.title,'score',x.score,'max_score',a.max_score,'submitted_at',x.submitted_at))
    from public.submissions x join public.activities a on a.id=x.activity_id where x.student_id=v_student
  ),'[]'::jsonb)
 ) into v_result from public.students s join public.school_classes c on c.id=s.class_id where s.id=v_student and s.active;
 if v_result is null then raise exception 'Student unavailable'; end if;
 return v_result;
end $function$;
create function hub_internal.student_submit_quiz(p_student uuid,p_activity_id uuid,p_answers jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_student public.students%rowtype; v_activity public.activities%rowtype; v_question jsonb; v_score numeric:=0; v_attempt integer;
begin
 select s.* into v_student from public.students s where s.id=p_student and s.active;
 if not found then raise exception 'Student account not linked'; end if;
 select a.* into v_activity from public.activities a join public.activity_targets t on t.activity_id=a.id
 where a.id=p_activity_id and t.class_id=v_student.class_id and a.published=true;
 if not found then raise exception 'Activity unavailable'; end if;
 if jsonb_typeof(p_answers) is distinct from 'object' then raise exception 'Invalid answers'; end if;
 if coalesce(jsonb_array_length(v_activity.answer_key->'questions'),0)=0 then raise exception 'Activity has no questions'; end if;
 if (select count(*) from jsonb_object_keys(p_answers))<>jsonb_array_length(v_activity.answer_key->'questions') then raise exception 'Answer all questions'; end if;
 for v_question in select value from jsonb_array_elements(v_activity.answer_key->'questions') loop
  if not coalesce((v_question->'choices') @> jsonb_build_array(p_answers->(v_question->>'id')),false) then raise exception 'Invalid choice'; end if;
 end loop;
 perform pg_advisory_xact_lock(hashtext(v_student.id::text||p_activity_id::text));
 select coalesce(max(attempt),0)+1 into v_attempt from public.submissions where student_id=v_student.id and activity_id=p_activity_id;
 if v_attempt>v_activity.max_attempts then raise exception 'No attempts remaining'; end if;
 for v_question in select value from jsonb_array_elements(coalesce(v_activity.answer_key->'questions','[]'::jsonb)) loop
  if p_answers->(v_question->>'id')=v_question->'correct' then
   v_score:=v_score+coalesce((v_question->>'points')::numeric,0);
  end if;
 end loop;
 v_score:=least(v_score,v_activity.max_score);
 insert into public.submissions(student_id,activity_id,attempt,responses,score,status)
 values(v_student.id,p_activity_id,v_attempt,p_answers,v_score,'reviewed');
 return jsonb_build_object('score',v_score,'max_score',v_activity.max_score,'attempt',v_attempt);
end $function$;


revoke all on all functions in schema hub_internal from public,anon,authenticated;

create or replace function public.student_dashboard()
returns jsonb language sql security definer set search_path='' as $$
select hub_internal.student_dashboard((select student_id from public.student_accounts where user_id=auth.uid()))
$$;
create or replace function public.student_submit_quiz(p_activity_id uuid,p_answers jsonb)
returns jsonb language sql security definer set search_path='' as $$
select hub_internal.student_submit_quiz((select student_id from public.student_accounts where user_id=auth.uid()),p_activity_id,p_answers)
$$;

create function public.hub_issue_student_code(p_student uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare token text:=encode(extensions.gen_random_bytes(24),'hex'); pin text; bytes bytea; n integer;
begin
 if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
 if not exists(select 1 from public.students where id=p_student and active) then raise exception 'Student unavailable'; end if;
 loop
   bytes:=extensions.gen_random_bytes(2);
   n:=get_byte(bytes,0)*256+get_byte(bytes,1);
   exit when n<60000;
 end loop;
 pin:=lpad((n%10000)::text,4,'0');
 insert into hub_internal.student_codes(student_id,invite_hash,pin_hash,expires_at)
 values(p_student,extensions.digest(token,'sha256'),extensions.crypt(pin,extensions.gen_salt('bf',10)),now()+interval '90 days')
 on conflict(student_id) do update set invite_hash=excluded.invite_hash,pin_hash=excluded.pin_hash,expires_at=excluded.expires_at,
   failures=0,window_since=null;
 return jsonb_build_object('invite',token,'pin',pin);
end $$;

create function public.hub_revoke_student_code(p_student uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
 update hub_internal.student_codes set expires_at=now() where student_id=p_student;
end $$;

create function public.hub_student_code(p_invite text,p_pin text,p_activity uuid default null,p_answers jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cred hub_internal.student_codes%rowtype;
begin
 if p_invite is null or p_invite !~ '^[0-9a-f]{48}$' or p_pin is null or p_pin !~ '^[0-9]{4}$' then return null; end if;
 select c.* into cred from hub_internal.student_codes c join public.students s on s.id=c.student_id
 where c.invite_hash=extensions.digest(p_invite,'sha256') and c.expires_at>now() and s.active for update of c;
 if not found then return null; end if;
 if cred.window_since is null or cred.window_since<=now()-interval '30 minutes' then
   cred.window_since:=now(); cred.failures:=0;
 end if;
 if cred.failures>=5 then return null; end if;
 if extensions.crypt(p_pin,cred.pin_hash) is distinct from cred.pin_hash then
   update hub_internal.student_codes set failures=cred.failures+1,window_since=cred.window_since where student_id=cred.student_id;
   return null;
 end if;
 if p_activity is not null then return hub_internal.student_submit_quiz(cred.student_id,p_activity,p_answers); end if;
 return hub_internal.student_dashboard(cred.student_id);
end $$;
revoke all on function public.hub_issue_student_code(uuid),public.hub_revoke_student_code(uuid),
 public.hub_student_code(text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.hub_issue_student_code(uuid),public.hub_revoke_student_code(uuid) to authenticated;
grant execute on function public.hub_student_code(text,text,uuid,jsonb) to anon,authenticated;
