alter table public.parent_access
  add column invite_hash bytea unique,
  add column expires_at timestamptz,
  add column failed_attempts integer not null default 0,
  add column failed_since timestamptz;

alter table public.honors add column category integer not null default 6
  check (category between 6 and 11);

create function public.hub_create_activity(p_title text,p_class uuid,p_kind text,p_unit integer,p_skill text,p_attempts integer,p_questions jsonb)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_id uuid; v_course text; q jsonb;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then
    raise exception 'الصلاحية للمعلمة';
  end if;
  select course into strict v_course from public.school_classes where id=p_class;
  if jsonb_typeof(p_questions) is distinct from 'array' or jsonb_array_length(p_questions) not between 1 and 100 then
    raise exception 'أضيفي من سؤال واحد إلى 100 سؤال';
  end if;
  for q in select value from jsonb_array_elements(p_questions) loop
    if coalesce(length(btrim(q->>'prompt')),0)=0 or jsonb_typeof(q->'choices') is distinct from 'array'
      or jsonb_array_length(q->'choices') not between 2 and 10
      or not coalesce((q->'choices') @> jsonb_build_array(q->'correct'),false)
      or q->>'id' is null or (q->>'points')::integer is distinct from 1 then
      raise exception 'السؤال أو الخيارات غير صالحة';
    end if;
  end loop;
  if (select count(distinct value->>'id') from jsonb_array_elements(p_questions))<>jsonb_array_length(p_questions) then
    raise exception 'معرّفات الأسئلة مكررة';
  end if;
  insert into public.activities(title,kind,course,unit_no,skill,max_score,max_attempts,answer_key,published)
  values(btrim(p_title),p_kind,v_course,p_unit,p_skill,jsonb_array_length(p_questions),p_attempts,
    jsonb_build_object('questions',p_questions),false) returning id into v_id;
  insert into public.activity_targets(activity_id,class_id) values(v_id,p_class);
  return v_id;
end $$;

create function public.hub_issue_family(p_student_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_pin text; v_invite text;
begin
  select public.teacher_issue_parent_pin(p_student_id) into v_pin;
  select public.hub_set_family_invite(p_student_id) into v_invite;
  return jsonb_build_object('pin',v_pin,'invite',v_invite);
end $$;

create function public.hub_set_family_invite(p_student_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_invite text:=encode(extensions.gen_random_bytes(24),'hex');
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  update public.parent_access set invite_hash=extensions.digest(v_invite,'sha256'),
    expires_at=now()+interval '30 days',failed_attempts=0,failed_since=null
  where student_id=p_student_id and revoked_at is null;
  if not found then raise exception 'No active invitation'; end if;
  return v_invite;
end $$;

create function public.hub_family(p_invite text,p_pin text,p_message text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_access public.parent_access%rowtype;
begin
  if p_invite is null or p_invite !~ '^[0-9a-f]{48}$' or p_pin is null or p_pin !~ '^[0-9]{4}$' then return null; end if;
  select * into v_access from public.parent_access
  where invite_hash=extensions.digest(p_invite,'sha256') and revoked_at is null and expires_at>now()
    and exists(select 1 from public.students s where s.id=student_id and s.active)
  for update;
  if not found then return null; end if;
  if v_access.failed_since is null or v_access.failed_since <= now()-interval '30 minutes' then
    v_access.failed_attempts:=0;
    v_access.failed_since:=now();
  end if;
  if v_access.failed_attempts>=5 then return null; end if;
  if extensions.crypt(p_pin,v_access.code_hash) is distinct from v_access.code_hash then
    update public.parent_access set failed_attempts=v_access.failed_attempts+1,failed_since=v_access.failed_since
    where student_id=v_access.student_id;
    return null;
  end if;
  if p_message is not null then
    if length(btrim(p_message)) not between 1 and 1000 then raise exception 'Invalid message length'; end if;
    if (select count(*) from public.parent_messages where student_id=v_access.student_id and created_at>now()-interval '1 hour')>=10
      then raise exception 'Message limit reached'; end if;
    insert into public.parent_messages(student_id,message) values(v_access.student_id,btrim(p_message));
  end if;
  return jsonb_build_object(
    'student',(select jsonb_build_object('name',s.full_name,'class_name',c.name) from public.students s join public.school_classes c on c.id=s.class_id where s.id=v_access.student_id),
    'results',(select coalesce(jsonb_agg(x order by x.submitted_at desc),'[]') from (
      select a.title,s.score,a.max_score,s.submitted_at from public.submissions s join public.activities a on a.id=s.activity_id
      where s.student_id=v_access.student_id and s.status in ('reviewed','returned') order by s.submitted_at desc limit 100) x),
    'messages',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (
      select message,teacher_reply,created_at from public.parent_messages where student_id=v_access.student_id order by created_at desc limit 50) x),
    'honors',(select coalesce(jsonb_agg(x order by x.week_start desc),'[]') from (
      select title,week_start from public.honors where student_id=v_access.student_id order by week_start desc limit 50) x));
end $$;

revoke execute on function public.hub_family(text,text,text) from public,anon,authenticated;
grant execute on function public.hub_family(text,text,text) to anon,authenticated;
revoke execute on function public.hub_create_activity(text,uuid,text,integer,text,integer,jsonb),
  public.hub_issue_family(uuid),public.hub_set_family_invite(uuid) from public,anon,authenticated;
grant execute on function public.hub_create_activity(text,uuid,text,integer,text,integer,jsonb),
  public.hub_issue_family(uuid),public.hub_set_family_invite(uuid) to authenticated;

alter table public.honors add column description text;
create table public.hub_plans(
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id),
  kind text not null check(kind in ('remedial','enrichment')),
  title text not null check(length(btrim(title)) between 1 and 160),
  instructions text not null check(length(btrim(instructions)) between 1 and 4000),
  due_on date not null,
  completed boolean not null default false
);
alter table public.hub_plans enable row level security;
revoke all on public.hub_plans from anon, authenticated;
grant select,insert,update on public.hub_plans to authenticated;
create policy "teachers manage plans" on public.hub_plans for all to authenticated
using (exists(select 1 from public.staff_roles where user_id=(select auth.uid()) and role='teacher'))
with check (exists(select 1 from public.staff_roles where user_id=(select auth.uid()) and role='teacher'));

create function public.hub_link_student(p_student_id uuid,p_email text)
returns void language plpgsql security definer set search_path='' as $$
declare v_user uuid;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  select id into v_user from auth.users where lower(email)=lower(btrim(p_email)) and email_confirmed_at is not null;
  if v_user is null or exists(select 1 from public.staff_roles where user_id=v_user) then raise exception 'A confirmed student account is required'; end if;
  insert into public.student_accounts(user_id,student_id) values(v_user,p_student_id);
end $$;
revoke execute on function public.hub_link_student(uuid,text) from public,anon,authenticated;
grant execute on function public.hub_link_student(uuid,text) to authenticated;

CREATE OR REPLACE FUNCTION public.student_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_student uuid; v_result jsonb;
begin
 select sa.student_id into v_student from public.student_accounts sa where sa.user_id=auth.uid();
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
CREATE OR REPLACE FUNCTION public.student_submit_quiz(p_activity_id uuid, p_answers jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_student public.students%rowtype; v_activity public.activities%rowtype; v_question jsonb; v_score numeric:=0; v_attempt integer;
begin
 select s.* into v_student from public.students s join public.student_accounts sa on sa.student_id=s.id where sa.user_id=auth.uid() and s.active;
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

do $$
declare t text;
begin
  foreach t in array array['students','activities','activity_targets','submissions','honors','parent_messages','semester_archives'] loop
    execute format('create policy "restrict detailed data to teachers" on public.%I as restrictive for select to authenticated using (exists(select 1 from public.staff_roles where user_id=(select auth.uid()) and role=''teacher''))',t);
  end loop;
end $$;

create function public.hub_admin_summary()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role in ('principal','vice_principal')) then
    raise exception 'Forbidden';
  end if;
  return jsonb_build_object('classes',(select count(*) from public.school_classes),
    'students',(select count(*) from public.students where active),
    'activities',(select count(*) from public.activities where published),
    'submissions',(select count(*) from public.submissions));
end $$;
revoke execute on function public.hub_admin_summary() from public,anon,authenticated;
grant execute on function public.hub_admin_summary() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('hub-private','hub-private',false,10485760,array['application/pdf','image/jpeg','image/png','audio/mpeg','audio/ogg']);

create policy "hub teachers upload resources" on storage.objects for insert to authenticated
with check (bucket_id='hub-private' and exists(
  select 1 from public.staff_roles where user_id=(select auth.uid()) and role='teacher'));
create policy "hub teachers replace resources" on storage.objects for update to authenticated
using (bucket_id='hub-private' and exists(
  select 1 from public.staff_roles where user_id=(select auth.uid()) and role='teacher'))
with check (bucket_id='hub-private' and exists(
  select 1 from public.staff_roles where user_id=(select auth.uid()) and role='teacher'));

create function public.hub_may_read_resource(p_name text)
returns boolean language sql stable security definer set search_path='' as $$
select auth.uid() is not null and (
  exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher')
  or exists(select 1 from public.student_accounts sa join public.students s on s.id=sa.student_id
    join public.activity_targets t on t.class_id=s.class_id join public.activities a on a.id=t.activity_id
    where sa.user_id=auth.uid() and s.active and a.published and p_name='units/'||a.id||'/resource')
  or exists(select 1 from public.student_accounts sa join public.students s on s.id=sa.student_id
    join public.honors h on h.student_id=s.id
    where sa.user_id=auth.uid() and s.active and p_name='honors/'||h.id||'/resource')
);
$$;
revoke execute on function public.hub_may_read_resource(text) from public,anon,authenticated;
grant execute on function public.hub_may_read_resource(text) to authenticated;
create policy "hub resource access" on storage.objects for select to authenticated
using (bucket_id='hub-private' and public.hub_may_read_resource(name));
