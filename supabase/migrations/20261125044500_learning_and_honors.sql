alter table public.hub_plans
  add column if not exists unit_no smallint check (unit_no between 1 and 20),
  add column if not exists skill text check (char_length(skill) <= 80);
alter table public.honors add column if not exists archived_at timestamptz;

create table hub_internal.plan_tasks (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.hub_plans(id),
  position smallint not null check (position between 1 and 30),
  day_no smallint not null check (day_no between 1 and 7),
  skill text not null check (skill in ('vocabulary','grammar','reading','listening','speaking','writing')),
  prompt text not null check (char_length(prompt) between 1 and 1200),
  expected text check (char_length(expected) between 1 and 300),
  unique(plan_id,position),
  check ((skill in ('speaking','writing')) = (expected is null))
);

create table hub_internal.plan_answers (
  task_id uuid primary key references hub_internal.plan_tasks(id),
  response text check (char_length(response) between 1 and 6000),
  score integer check (score between 0 and 100),
  feedback text check (char_length(feedback) <= 1500),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table hub_internal.learning_media (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id),
  task_id uuid unique references hub_internal.plan_answers(task_id),
  honor_id uuid unique references public.honors(id),
  mime text not null,
  content bytea not null check (octet_length(content) between 1 and 1572864),
  check ((task_id is null) <> (honor_id is null))
);
create index on hub_internal.learning_media(student_id);
alter table hub_internal.plan_tasks enable row level security;
alter table hub_internal.plan_answers enable row level security;
alter table hub_internal.learning_media enable row level security;

create function hub_internal.learning_teacher()
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.staff_roles r where r.user_id=auth.uid() and r.role='teacher')
$$;

create function hub_internal.learning_student(p_token text)
returns uuid language sql stable set search_path='' as $$
  select s.id from public.students s
  where s.active and (
    (p_token is null and exists(select 1 from public.student_accounts a where a.student_id=s.id and a.user_id=auth.uid()))
    or
    (p_token ~ '^[0-9a-f]{64}$' and exists(
      select 1 from hub_internal.student_sessions q
      join hub_internal.student_codes c on c.student_id=q.student_id and c.invite_hash=q.credential_hash
      where q.student_id=s.id and q.token_hash=extensions.digest(p_token,'sha256') and q.expires_at>now() and c.expires_at>now()
    ))
  )
$$;

create function public.hub_assign_learning_plan(
 p_class uuid,p_student uuid,p_kind text,p_title text,p_instructions text,p_due date,p_unit integer,p_skill text,p_tasks jsonb
) returns integer language plpgsql security definer set search_path='' as $$
declare member record; new_plan uuid; assigned integer:=0; item jsonb; item_no integer;
begin
 if not hub_internal.learning_teacher() then raise exception 'Forbidden'; end if;
 if (p_class is null)=(p_student is null) or p_kind is null or p_kind not in ('remedial','enrichment') or
    p_unit is null or p_unit not between 1 and 20 or nullif(btrim(p_skill),'') is null or p_due is null then
   raise exception 'Invalid plan';
 end if;
 if jsonb_typeof(p_tasks) is distinct from 'array' or jsonb_array_length(p_tasks) not between 1 and 30 then
   raise exception 'Invalid plan tasks';
 end if;
 if p_kind='remedial' and not (
    (select count(*) from jsonb_array_elements(p_tasks) x where x->>'skill'='vocabulary')=12
    and (select count(*) from jsonb_array_elements(p_tasks) x where x->>'skill'='grammar') in (2,3)
    and jsonb_array_length(p_tasks) in (14,15)
    and not exists(select 1 from generate_series(1,3) day where
      (select count(*) from jsonb_array_elements(p_tasks) x where x->>'skill'='vocabulary' and (x->>'day')::integer=day)<>4)
    and (select count(distinct (x->>'day')::integer) from jsonb_array_elements(p_tasks) x where x->>'skill'='grammar' and (x->>'day')::integer between 4 and 6)
    = jsonb_array_length(p_tasks)-12
 ) then raise exception 'Remedial plans require twelve vocabulary items across the first three days and grammar across two or three more days'; end if;
 if p_kind='enrichment' and exists(select 1 from jsonb_array_elements(p_tasks) x where x->>'skill' not in ('reading','listening','speaking','writing')) then
   raise exception 'Invalid enrichment skill';
 end if;
 for member in select id from public.students where active and (id=p_student or class_id=p_class) order by id loop
   insert into public.hub_plans(student_id,kind,title,instructions,due_on,unit_no,skill)
   values(member.id,p_kind,btrim(p_title),btrim(p_instructions),p_due,p_unit,btrim(p_skill))
   returning id into new_plan;
   item_no:=0;
   for item in select value from jsonb_array_elements(p_tasks) loop
     item_no:=item_no+1;
     insert into hub_internal.plan_tasks(plan_id,position,day_no,skill,prompt,expected)
     values(new_plan,item_no,(item->>'day')::smallint,item->>'skill',btrim(item->>'prompt'),nullif(btrim(item->>'expected'),''));
   end loop;
   assigned:=assigned+1;
 end loop;
 if assigned=0 then raise exception 'No active students match the plan'; end if;
 return assigned;
end $$;

create function hub_internal.store_learning_media(p_student uuid,p_task uuid,p_honor uuid,p_mime text,p_base64 text)
returns uuid language plpgsql set search_path='' as $$
declare bytes bytea; result uuid;
begin
 if p_base64 is null or length(p_base64)>2097152 then raise exception 'Maximum attachment size is 1.5 MB'; end if;
 bytes:=decode(p_base64,'base64');
 if p_mime is null or (case p_mime
   when 'application/pdf' then substring(bytes from 1 for 5)=decode('255044462d','hex')
   when 'audio/mpeg' then substring(bytes from 1 for 3)=decode('494433','hex') or substring(bytes from 1 for 2) in (decode('fffb','hex'),decode('fff3','hex'),decode('fff2','hex'))
   when 'audio/ogg' then substring(bytes from 1 for 4)=decode('4f676753','hex')
   when 'audio/wav' then substring(bytes from 1 for 4)=decode('52494646','hex') and substring(bytes from 9 for 4)=decode('57415645','hex')
   when 'audio/mp4' then substring(bytes from 5 for 4)=decode('66747970','hex')
   when 'audio/webm' then substring(bytes from 1 for 4)=decode('1a45dfa3','hex')
   when 'image/jpeg' then substring(bytes from 1 for 3)=decode('ffd8ff','hex')
   when 'image/png' then substring(bytes from 1 for 8)=decode('89504e470d0a1a0a','hex')
   when 'video/mp4' then substring(bytes from 5 for 4)=decode('66747970','hex')
   else false end) is not true then raise exception 'Unrecognized file format'; end if;
 if p_task is not null and p_mime not in ('application/pdf','audio/mpeg','audio/ogg','audio/wav','audio/mp4','audio/webm')
   or p_honor is not null and p_mime not in ('image/jpeg','image/png','video/mp4') then raise exception 'Invalid file type'; end if;
 perform pg_advisory_xact_lock(1347596877);
 if p_honor is not null then
   delete from hub_internal.learning_media where honor_id=p_honor;
 end if;
 if (select coalesce(sum(octet_length(content)),0) from hub_internal.learning_media where student_id=p_student)+octet_length(bytes)>5242880
   or (select coalesce(sum(octet_length(content)),0) from hub_internal.learning_media)+octet_length(bytes)>52428800 then
   raise exception 'Attachment quota reached';
 end if;
 insert into hub_internal.learning_media(student_id,task_id,honor_id,mime,content)
 values(p_student,p_task,p_honor,p_mime,bytes) returning id into result;
 return result;
end $$;

create function public.hub_student_learning(p_token text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare student uuid:=hub_internal.learning_student(p_token);
begin
 if student is null then return null; end if;
 return jsonb_build_object('plans',coalesce((
   select jsonb_agg(jsonb_build_object(
     'id',p.id,'title',p.title,'kind',p.kind,'unit',p.unit_no,'skill',p.skill,
     'tasks',coalesce((
       select jsonb_agg(jsonb_build_object('id',t.id,'day',t.day_no,'skill',t.skill,'prompt',t.prompt,
         'submitted',a.task_id is not null,'reviewed',a.reviewed_at is not null,'score',a.score,'feedback',a.feedback,'media',m.id) order by t.position)
       from hub_internal.plan_tasks t
       left join hub_internal.plan_answers a on a.task_id=t.id
       left join hub_internal.learning_media m on m.task_id=t.id
       where t.plan_id=p.id
     ),'[]'::jsonb)
   ) order by p.due_on,p.id) from public.hub_plans p where p.student_id=student and p.unit_no is not null
 ),'[]'::jsonb),'honors',coalesce((
   select jsonb_agg(jsonb_build_object('id',h.id,'title',h.title,'category',h.category,'description',h.description,'week_start',h.week_start,'media',m.id,
     'legacy',exists(select 1 from storage.objects o where o.bucket_id='hub-private' and o.name='honors/'||h.id||'/resource')
   ) order by h.week_start desc,h.id)
   from public.honors h left join hub_internal.learning_media m on m.honor_id=h.id where h.student_id=student and h.archived_at is null
 ),'[]'::jsonb));
end $$;

create function hub_internal.refresh_learning_completion(p_plan uuid)
returns void language sql set search_path='' as $$
 update public.hub_plans p set completed=true where p.id=p_plan and not exists(
   select 1 from hub_internal.plan_tasks t
   left join hub_internal.plan_answers a on a.task_id=t.id
   where t.plan_id=p_plan and a.reviewed_at is null
 )
$$;

create function public.hub_submit_learning_task(p_token text,p_task uuid,p_response text,p_mime text default null,p_base64 text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare student uuid:=hub_internal.learning_student(p_token); task hub_internal.plan_tasks%rowtype; result integer; clean text:=nullif(btrim(p_response),'');
begin
 if student is null then return null; end if;
 select t.* into task from hub_internal.plan_tasks t join public.hub_plans p on p.id=t.plan_id
 where t.id=p_task and p.student_id=student;
 if not found then raise exception 'Unavailable task'; end if;
 perform pg_advisory_xact_lock(hashtextextended(task.plan_id::text,65311));
 if task.expected is not null then
   if clean is null or p_base64 is not null then raise exception 'Enter a written answer'; end if;
   result:=case when lower(regexp_replace(clean,'[[:space:]]+',' ','g'))=lower(regexp_replace(task.expected,'[[:space:]]+',' ','g')) then 100 else 0 end;
 elsif (task.skill='speaking' and (p_base64 is null or p_mime not in ('audio/mpeg','audio/ogg','audio/wav','audio/mp4','audio/webm')))
       or (task.skill='writing' and clean is null and p_base64 is null)
       or (task.skill='writing' and p_base64 is not null and p_mime is distinct from 'application/pdf') then
   raise exception 'Required response or file is missing';
 end if;
 insert into hub_internal.plan_answers(task_id,response,score,reviewed_at) values(task.id,clean,result,case when result is not null then now() end)
 on conflict (task_id) do nothing;
 if not found then raise exception 'This task was already submitted'; end if;
 if p_base64 is not null then perform hub_internal.store_learning_media(student,task.id,null,p_mime,p_base64); end if;
 perform hub_internal.refresh_learning_completion(task.plan_id);
 return jsonb_build_object('score',result,'reviewed',result is not null);
end $$;

create function public.hub_learning_reviews(p_kind text)
returns table(id uuid,student_id uuid,title text,skill text,prompt text,response text,score integer,feedback text,media uuid,submitted_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if not hub_internal.learning_teacher() then raise exception 'Forbidden'; end if;
 return query select t.id,p.student_id,p.title,t.skill,t.prompt,a.response,a.score,a.feedback,m.id,a.submitted_at
 from hub_internal.plan_answers a join hub_internal.plan_tasks t on t.id=a.task_id
 join public.hub_plans p on p.id=t.plan_id left join hub_internal.learning_media m on m.task_id=a.task_id
 where p.kind=p_kind order by a.reviewed_at nulls first,a.submitted_at desc;
end $$;

create function public.hub_review_learning_task(p_task uuid,p_score integer,p_feedback text)
returns void language plpgsql security definer set search_path='' as $$
declare plan uuid;
begin
 if not hub_internal.learning_teacher() then raise exception 'Forbidden'; end if;
 select plan_id into plan from hub_internal.plan_tasks where id=p_task and expected is null;
 if not found or p_score is null then raise exception 'Invalid review'; end if;
 perform pg_advisory_xact_lock(hashtextextended(plan::text,65311));
 update hub_internal.plan_answers set score=p_score,feedback=btrim(p_feedback),reviewed_at=now() where task_id=p_task;
 if not found then raise exception 'Unavailable submission'; end if;
 perform hub_internal.refresh_learning_completion(plan);
end $$;

create function public.hub_attach_honor(p_honor uuid,p_mime text,p_base64 text)
returns uuid language plpgsql security definer set search_path='' as $$
declare student uuid;
begin
 if not hub_internal.learning_teacher() then raise exception 'Forbidden'; end if;
 select student_id into student from public.honors where id=p_honor and archived_at is null;
 if not found then raise exception 'Unavailable honor'; end if;
 return hub_internal.store_learning_media(student,null,p_honor,p_mime,p_base64);
end $$;

create function public.hub_download_learning_media(p_media uuid,p_token text default null)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('mime',m.mime,'body',encode(m.content,'base64'))
 from hub_internal.learning_media m left join public.honors h on h.id=m.honor_id
 where m.id=p_media and (
   (p_token is null and hub_internal.learning_teacher()) or
   (m.student_id=hub_internal.learning_student(p_token) and (m.honor_id is null or h.archived_at is null))
 )
$$;

revoke all on function
 hub_internal.learning_teacher(),hub_internal.learning_student(text),
 hub_internal.store_learning_media(uuid,uuid,uuid,text,text),hub_internal.refresh_learning_completion(uuid)
 from public,anon,authenticated;
revoke all on function
 public.hub_assign_learning_plan(uuid,uuid,text,text,text,date,integer,text,jsonb),public.hub_student_learning(text),
 public.hub_submit_learning_task(text,uuid,text,text,text),public.hub_learning_reviews(text),public.hub_review_learning_task(uuid,integer,text),
 public.hub_attach_honor(uuid,text,text),public.hub_download_learning_media(uuid,text)
 from public,anon,authenticated;
grant execute on function public.hub_assign_learning_plan(uuid,uuid,text,text,text,date,integer,text,jsonb),
 public.hub_learning_reviews(text),public.hub_review_learning_task(uuid,integer,text),public.hub_attach_honor(uuid,text,text) to authenticated;
grant execute on function public.hub_student_learning(text),public.hub_submit_learning_task(text,uuid,text,text,text),
 public.hub_download_learning_media(uuid,text) to anon,authenticated;
