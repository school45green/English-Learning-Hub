create table public.activity_student_targets (
 activity_id uuid not null references public.activities(id),
 student_id uuid not null references public.students(id),
 primary key(activity_id,student_id)
);
alter table public.activity_student_targets enable row level security;
revoke all on public.activity_student_targets from public,anon,authenticated;
grant select on public.activity_student_targets to authenticated;
create policy hub_teacher_read_targets on public.activity_student_targets for select to authenticated
 using (exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher'));

create table hub_internal.activity_drafts (
 student_id uuid references public.students(id),
 activity_id uuid references public.activities(id),
 answers jsonb not null default '{}',
 revision integer not null default 0,
 primary key(student_id,activity_id)
);
create table hub_internal.activity_extra_attempts (
 student_id uuid references public.students(id),
 activity_id uuid references public.activities(id),
 extra integer not null check(extra between 1 and 100),
 primary key(student_id,activity_id)
);
alter table hub_internal.activity_drafts enable row level security;
alter table hub_internal.activity_extra_attempts enable row level security;

create function hub_internal.activity_assigned(p_student uuid,p_activity uuid)
returns boolean language sql stable set search_path='' as $$
select exists (
 select 1 from public.students s join public.school_classes c on c.id=s.class_id
 where s.id=p_student and s.active and c.archived_at is null and (
  exists (select 1 from public.activity_targets t where t.activity_id=p_activity and t.class_id=s.class_id)
  or exists (select 1 from public.activity_student_targets t where t.activity_id=p_activity and t.student_id=s.id)
 )
)
$$;
create function hub_internal.activity_attempt_limit(p_student uuid,p_activity uuid)
returns integer language sql stable set search_path='' as $$
select a.max_attempts+coalesce(e.extra,0) from public.activities a
left join hub_internal.activity_extra_attempts e on e.activity_id=a.id and e.student_id=p_student where a.id=p_activity
$$;

create function public.hub_create_scoped_activity(p_title text,p_classes uuid[],p_students uuid[],p_kind text,p_unit integer,p_skill text,p_attempts integer,p_questions jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_course text; q jsonb; v_target uuid;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then
    raise exception 'الصلاحية للمعلمة';
  end if;
  if coalesce(cardinality(p_classes),0)+coalesce(cardinality(p_students),0) not between 1 and 1000 then
    raise exception 'اختاري فصلًا أو طالبة واحدة على الأقل';
  end if;
  for v_target in select distinct unnest(p_classes) loop
    select coalesce(v_course,c.course) into strict v_course from public.school_classes c
      where c.id=v_target and c.archived_at is null and (v_course is null or c.course=v_course);
  end loop;
  for v_target in select distinct unnest(p_students) loop
    select coalesce(v_course,c.course) into strict v_course from public.students s join public.school_classes c on c.id=s.class_id
      where s.id=v_target and s.active and c.archived_at is null and (v_course is null or c.course=v_course);
  end loop;
  if jsonb_typeof(p_questions) is distinct from 'array' or jsonb_array_length(p_questions) not between 1 and 100 then
    raise exception 'أضيفي من سؤال واحد إلى 100 سؤال';
  end if;
  for q in select value from jsonb_array_elements(p_questions) loop
    if coalesce(length(btrim(q->>'prompt')),0)=0 or jsonb_typeof(q->'choices') is distinct from 'array'
      or jsonb_array_length(q->'choices') not between 2 and 10
      or not coalesce((q->'choices') @> jsonb_build_array(q->'correct'),false)
      or q->>'id' is null or coalesce((q->>'points')::integer,0) not between 1 and 20 then
      raise exception 'السؤال أو الخيارات غير صالحة';
    end if;
  end loop;
  if (select count(distinct value->>'id') from jsonb_array_elements(p_questions))<>jsonb_array_length(p_questions) then
    raise exception 'معرّفات الأسئلة مكررة';
  end if;
  insert into public.activities(title,kind,course,unit_no,skill,max_score,max_attempts,answer_key,published)
  values(btrim(p_title),p_kind,v_course,p_unit,p_skill,(select sum((value->>'points')::integer) from jsonb_array_elements(p_questions)),p_attempts,
    jsonb_build_object('questions',p_questions),false) returning id into v_id;
  insert into public.activity_targets(activity_id,class_id) select v_id,id from (select distinct unnest(p_classes) id) x;
  insert into public.activity_student_targets(activity_id,student_id) select v_id,id from (select distinct unnest(p_students) id) x;
  return v_id;
end $$;

create or replace function hub_internal.student_dashboard(v_student uuid)
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
    ),'attempts_used',(select count(*) from public.submissions x where x.student_id=v_student and x.activity_id=a.id),'max_attempts',hub_internal.activity_attempt_limit(v_student,a.id),'draft',coalesce(d.answers,'{}'),'draft_revision',coalesce(d.revision,0)))
    from public.activities a left join hub_internal.activity_drafts d on d.activity_id=a.id and d.student_id=v_student
    where a.published and hub_internal.activity_assigned(v_student,a.id)
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
create or replace function hub_internal.student_submit_quiz(p_student uuid,p_activity_id uuid,p_answers jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_student public.students%rowtype; v_activity public.activities%rowtype; v_question jsonb; v_score numeric:=0; v_attempt integer;
begin
 select s.* into v_student from public.students s where s.id=p_student and s.active;
 if not found then raise exception 'Student account not linked'; end if;
 select a.* into v_activity from public.activities a
 where a.id=p_activity_id and a.published and hub_internal.activity_assigned(p_student,a.id);
 if not found then raise exception 'Activity unavailable'; end if;
 if jsonb_typeof(p_answers) is distinct from 'object' then raise exception 'Invalid answers'; end if;
 if coalesce(jsonb_array_length(v_activity.answer_key->'questions'),0)=0 then raise exception 'Activity has no questions'; end if;
 if (select count(*) from jsonb_object_keys(p_answers))<>jsonb_array_length(v_activity.answer_key->'questions') then raise exception 'Answer all questions'; end if;
 for v_question in select value from jsonb_array_elements(v_activity.answer_key->'questions') loop
  if not coalesce((v_question->'choices') @> jsonb_build_array(p_answers->(v_question->>'id')),false) then raise exception 'Invalid choice'; end if;
 end loop;
 perform pg_advisory_xact_lock(hashtext(v_student.id::text||p_activity_id::text));
 select coalesce(max(attempt),0)+1 into v_attempt from public.submissions where student_id=v_student.id and activity_id=p_activity_id;
 if v_attempt>hub_internal.activity_attempt_limit(p_student,p_activity_id) then raise exception 'No attempts remaining'; end if;
 for v_question in select value from jsonb_array_elements(coalesce(v_activity.answer_key->'questions','[]'::jsonb)) loop
  if p_answers->(v_question->>'id')=v_question->'correct' then
   v_score:=v_score+coalesce((v_question->>'points')::numeric,0);
  end if;
 end loop;
 v_score:=least(v_score,v_activity.max_score);
 insert into public.submissions(student_id,activity_id,attempt,responses,score,status)
 values(v_student.id,p_activity_id,v_attempt,p_answers,v_score,'reviewed');
 update hub_internal.activity_drafts set answers='{}',revision=revision+1 where student_id=p_student and activity_id=p_activity_id;
 return jsonb_build_object('score',v_score,'max_score',v_activity.max_score,'attempt',v_attempt);
end $function$;



create function public.hub_save_activity_draft(p_token text,p_activity uuid,p_answers jsonb,p_revision integer,p_attempt integer)
returns integer language plpgsql security definer set search_path='' as $$
declare s uuid:=hub_internal.learning_student(p_token); questions jsonb; result integer; attempt integer;
begin
 if s is null then raise exception 'Session expired'; end if;
 perform pg_advisory_xact_lock(hashtext(s::text||p_activity::text));
 select a.answer_key->'questions' into questions from public.activities a
   where a.id=p_activity and a.published and hub_internal.activity_assigned(s,a.id);
 if questions is null or jsonb_typeof(p_answers) is distinct from 'object'
   or exists(select 1 from jsonb_each(p_answers) item
     where not exists(select 1 from jsonb_array_elements(questions) q
       where q->>'id'=item.key and q->'choices' @> jsonb_build_array(item.value))) then
   raise exception 'Invalid draft';
 end if;
 select coalesce(max(x.attempt),0)+1 into attempt from public.submissions x where x.student_id=s and x.activity_id=p_activity;
 if attempt is distinct from p_attempt or attempt>hub_internal.activity_attempt_limit(s,p_activity) then
   raise exception 'Attempt unavailable';
 end if;
 insert into hub_internal.activity_drafts(student_id,activity_id) values(s,p_activity) on conflict do nothing;
 update hub_internal.activity_drafts set answers=p_answers,revision=revision+1
   where student_id=s and activity_id=p_activity and revision=p_revision returning revision into result;
 if result is null then raise exception 'Draft changed elsewhere. Reopen the activity.'; end if;
 return result;
end $$;

create function public.hub_reopen_activity(p_student uuid,p_activity uuid)
returns void language plpgsql security definer set search_path='' as $$
declare used integer;
begin
 if not hub_internal.learning_teacher() then raise exception 'Forbidden'; end if;
 perform pg_advisory_xact_lock(hashtext(p_student::text||p_activity::text));
 if not hub_internal.activity_assigned(p_student,p_activity) then raise exception 'Activity unavailable'; end if;
 select coalesce(max(attempt),0) into used from public.submissions where student_id=p_student and activity_id=p_activity;
 if used<hub_internal.activity_attempt_limit(p_student,p_activity) then raise exception 'توجد محاولة متاحة لهذه الطالبة'; end if;
 insert into hub_internal.activity_extra_attempts values(p_student,p_activity,1)
 on conflict(student_id,activity_id) do update set extra=hub_internal.activity_extra_attempts.extra+1;
end $$;

revoke all on function hub_internal.activity_assigned(uuid,uuid),hub_internal.activity_attempt_limit(uuid,uuid) from public,anon,authenticated;
revoke all on function public.hub_create_scoped_activity(text,uuid[],uuid[],text,integer,text,integer,jsonb),
 public.hub_save_activity_draft(text,uuid,jsonb,integer,integer),public.hub_reopen_activity(uuid,uuid) from public,anon,authenticated;
grant execute on function public.hub_create_scoped_activity(text,uuid[],uuid[],text,integer,text,integer,jsonb),
 public.hub_reopen_activity(uuid,uuid) to authenticated;
grant execute on function public.hub_save_activity_draft(text,uuid,jsonb,integer,integer) to anon,authenticated;

create or replace function public.hub_family(p_invite text,p_pin text,p_message text default null)
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
    'student',(select jsonb_build_object('name',s.full_name,'class_name',c.name,'grade_level',c.grade_level,'course',c.course) from public.students s join public.school_classes c on c.id=s.class_id where s.id=v_access.student_id),
    'activities',(
      select coalesce(jsonb_agg(x order by x.unit_no nulls last,x.title),'[]')
      from (
        select a.title,a.unit_no,a.skill,a.kind,
          exists(select 1 from public.submissions s where s.student_id=v_access.student_id and s.activity_id=a.id) as submitted
        from public.activities a
        where a.published and hub_internal.activity_assigned(v_access.student_id,a.id)
        order by a.unit_no nulls last,a.title limit 250
      ) x
    ),
    'plans',(
      select coalesce(jsonb_agg(x order by x.due_on nulls last,x.title),'[]')
      from (
        select p.title,p.kind,p.unit_no,p.skill,p.instructions,p.due_on,p.completed
        from public.hub_plans p where p.student_id=v_access.student_id
        order by p.due_on nulls last,p.title limit 100
      ) x
    ),
    'results',(select coalesce(jsonb_agg(x order by x.submitted_at desc),'[]') from (
      select a.title,s.score,a.max_score,s.submitted_at from public.submissions s join public.activities a on a.id=s.activity_id
      where s.student_id=v_access.student_id and s.status in ('reviewed','returned') and s.score is not null order by s.submitted_at desc limit 100) x),
    'messages',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (
      select message,teacher_reply,created_at from public.parent_messages where student_id=v_access.student_id order by created_at desc limit 50) x),
    'honors',(select coalesce(jsonb_agg(x order by x.week_start desc),'[]') from (
      select title,week_start from public.honors where student_id=v_access.student_id and archived_at is null order by week_start desc limit 50) x));
end $$;

