create table hub_internal.fluency_files(id uuid primary key default gen_random_uuid(),mime text not null,content bytea not null);
create table hub_internal.fluency_tasks(
 id uuid primary key default gen_random_uuid(),title text not null check(length(title) between 1 and 200),skill text not null check(skill in ('listening','speaking','reading','writing')),
 level text not null check(level in ('beginner','intermediate','advanced')),prompt text not null check(length(prompt) between 1 and 16000),
 questions jsonb not null, file_id uuid references hub_internal.fluency_files, due_at timestamptz, attempts int not null check(attempts between 1 and 30),
 published boolean not null default false,archived boolean not null default false,revision int not null default 0,created_at timestamptz default now()
);
create table hub_internal.fluency_targets(task_id uuid references hub_internal.fluency_tasks,student_id uuid references public.students,primary key(task_id,student_id));
create table hub_internal.fluency_work(
 id uuid primary key default gen_random_uuid(),task_id uuid not null,student_id uuid not null, attempt int not null,
 answers jsonb, file_id uuid references hub_internal.fluency_files,score int check(score between 0 and 100),feedback text, submitted_at timestamptz not null default now(),
 foreign key(task_id,student_id) references hub_internal.fluency_targets,unique(task_id,student_id,attempt)
);
create index on hub_internal.fluency_targets(student_id);
alter table hub_internal.fluency_tasks enable row level security;
alter table hub_internal.fluency_targets enable row level security;
alter table hub_internal.fluency_work enable row level security;
alter table hub_internal.fluency_files enable row level security;
revoke all on hub_internal.fluency_tasks,hub_internal.fluency_targets,hub_internal.fluency_work,hub_internal.fluency_files from public,anon,authenticated;
create function hub_internal.fluency_file(p_mime text,p_base64 text) returns uuid language plpgsql set search_path='' as $$
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

 perform pg_advisory_xact_lock(1672190433);
 if (select coalesce(sum(octet_length(content)),0) from hub_internal.fluency_files)+octet_length(bytes)>104857600 then raise exception 'اكتملت مساحة مرفقات القسم';end if;
 insert into hub_internal.fluency_files(mime,content) values(p_mime,bytes) returning id into result;
 return result;
end $$;
create function hub_internal.fluency_progress(p_student uuid) returns jsonb language sql stable set search_path='' as $$
 with per_task as (
 select s.id,s.full_name,c.name class_name,t.id task,t.skill,
   exists(select 1 from hub_internal.fluency_work w where w.task_id=t.id and w.student_id=s.id) done,
   (select w.score from hub_internal.fluency_work w where w.task_id=t.id and w.student_id=s.id and w.score is not null order by attempt desc limit 1) score
 from public.students s join public.school_classes c on c.id=s.class_id
 join hub_internal.fluency_targets x on x.student_id=s.id join hub_internal.fluency_tasks t on t.id=x.task_id
 where (p_student is null or s.id=p_student) and s.active and c.archived_at is null and
 (t.published or exists(select 1 from hub_internal.fluency_work w where w.task_id=t.id and w.student_id=s.id))
 ), stats as (
 select s.id,s.full_name,c.name class_name,k.skill,count(p.task) total,count(p.task) filter(where done) completed,round(avg(p.score)) average
 from public.students s join public.school_classes c on c.id=s.class_id cross join unnest(array['listening','speaking','reading','writing']) k(skill)
 left join per_task p on p.id=s.id and p.skill=k.skill where s.active and c.archived_at is null and (p_student is null or s.id=p_student)
 group by s.id,s.full_name,c.name,k.skill)
 select coalesce(jsonb_agg(to_jsonb(stats)-'id'||jsonb_build_object('student_key',stats.id,'trend',(select coalesce(jsonb_agg(jsonb_build_array(dt,av) order by dt),'[]') from (
 select (w.submitted_at at time zone 'Asia/Riyadh')::date dt,round(avg(w.score)) av from hub_internal.fluency_work w join hub_internal.fluency_tasks t on t.id=w.task_id where w.student_id=stats.id and t.skill=stats.skill and w.score is not null group by 1) days)) order by class_name,full_name,skill),'[]') from stats
$$;
create function public.hub_fluency(p_op text,p_data jsonb default '{}',p_token text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare teacher boolean:=hub_internal.learning_teacher() and p_token is null; sid uuid; tid uuid:=(p_data->>'id')::uuid; t hub_internal.fluency_tasks%rowtype; f uuid; q jsonb; n int; points int:=0; result int; targets uuid[]; obj boolean; payload jsonb; filemime text;
begin
 if not teacher then sid:=hub_internal.learning_student(p_token); if sid is null then raise insufficient_privilege;end if; end if;
 if p_op='progress' then return hub_internal.fluency_progress(sid);end if;
 if p_op='list' then
 return (select coalesce(jsonb_agg((to_jsonb(a)-'questions')||jsonb_build_object('questions',case when teacher then a.questions else (select coalesce(jsonb_agg(v-'correct' order by ord),'[]') from jsonb_array_elements(a.questions) with ordinality x(v,ord)) end,
 'targets',case when teacher then (select jsonb_agg(student_id) from hub_internal.fluency_targets where task_id=a.id) end,
 'work',(select coalesce(jsonb_agg(to_jsonb(w)-'student_id'||jsonb_build_object('name',s.full_name) order by w.submitted_at desc),'[]') from hub_internal.fluency_work w join public.students s on s.id=w.student_id where w.task_id=a.id and (teacher or s.id=sid)))
 order by a.created_at desc),'[]') from hub_internal.fluency_tasks a where a.skill=p_data->>'skill' and
 ((teacher and not a.archived) or (not teacher and exists(select 1 from hub_internal.fluency_targets x where x.task_id=a.id and x.student_id=sid) and (a.published or exists(select 1 from hub_internal.fluency_work w where w.task_id=a.id and w.student_id=sid)))));
 end if;
 if p_op='file' then
 if not teacher and not exists(select 1 from hub_internal.fluency_targets x join hub_internal.fluency_tasks a on x.task_id=a.id where x.student_id=sid and a.published and a.file_id=tid)
 and not exists(select 1 from hub_internal.fluency_work where student_id=sid and file_id=tid) then raise insufficient_privilege;end if;
 return (select jsonb_build_object('mime',mime,'body',encode(content,'base64')) from hub_internal.fluency_files where id=tid);
 end if;
 if p_op='review' then
 if not teacher then raise insufficient_privilege;end if;
 update hub_internal.fluency_work w set score=(p_data->>'score')::int,feedback=left(p_data->>'feedback',4000) from hub_internal.fluency_tasks a
 where w.id=tid and w.task_id=a.id and a.skill in ('speaking','writing') and p_data->>'score' is not null;
 if not found then raise exception 'تعذّر حفظ التقييم';end if;return '{}';end if;
 if tid is not null then select * into strict t from hub_internal.fluency_tasks where id=tid and not archived for update;end if;
 if p_op='submit' then
 if teacher or not t.published or t.due_at<now() or not exists(select 1 from hub_internal.fluency_targets where task_id=tid and student_id=sid) then raise insufficient_privilege;end if;
 select count(*)+1 into n from hub_internal.fluency_work where task_id=tid and student_id=sid;
 if n>t.attempts then raise exception 'اكتملت المحاولات';end if;
 payload:=p_data->'answers';
 if t.skill in ('listening','reading') then
 if jsonb_typeof(payload) is distinct from 'array' or jsonb_array_length(payload)<>jsonb_array_length(t.questions) then raise exception 'أجيبي عن كل الأسئلة';end if;
 for i in 0..jsonb_array_length(t.questions)-1 loop
 q:=t.questions->i;
 if not (q->'choices' @> jsonb_build_array(payload->i)) then raise exception 'اختيار غير صالح';end if;
 if q->'correct'=payload->i then points:=points+1;end if;end loop;
 result:=round(100.0*points/jsonb_array_length(t.questions));
 elsif t.skill='speaking' then
 if coalesce(p_data->>'p_mime','') not like 'audio/%' then raise exception 'أرفقي تسجيلًا صوتيًا';end if;
 f:=hub_internal.fluency_file(p_data->>'p_mime',p_data->>'p_base64');payload:=null;
 elsif jsonb_typeof(payload) is distinct from 'string' or length(trim(payload#>>'{}')) not between 1 and 16000 then raise exception 'اكتبي إجابتك';end if;
 insert into hub_internal.fluency_work(task_id,student_id,attempt,answers,file_id,score) values(tid,sid,n,payload,f,result);return jsonb_build_object('score',result);
 end if;
 if not teacher then raise insufficient_privilege;end if;
 if tid is not null and (p_data->>'revision')::int is distinct from t.revision then raise exception 'تغير التدريب. أعيدي فتح البطاقة.';end if;
 if p_op='archive' or p_op='publish' then
 update hub_internal.fluency_tasks set published=case when p_op='archive' then false else (p_data->>'published')::boolean end,archived=p_op='archive',revision=revision+1 where id=tid;return '{}';end if;
 if p_op not in ('save','copy') then raise exception 'Unknown operation';end if;
 if p_op='copy' and tid is null then raise exception 'اختاري التدريب';end if;
 if tid is not null and p_op='save' and exists(select 1 from hub_internal.fluency_work where task_id=tid) then raise exception 'حُفظت محاولات لهذا التدريب. استخدمي نسخ لإنشاء إصدار معدّل.';end if;
 select array_agg(s.id) into targets from public.students s join public.school_classes c on c.id=s.class_id where s.active and c.archived_at is null and (
 p_data->'classes' ? c.id::text or p_data->'students' ? s.id::text);
 if targets is null then raise exception 'اختاري فصلًا أو طالبة';end if;
 obj:=p_data->>'skill' in ('reading','listening');payload:=coalesce(p_data->'questions','[]');
 if obj then
 if jsonb_typeof(payload)<>'array' or jsonb_array_length(payload) not between 1 and 50 then raise exception 'أضيفي أسئلة الفهم';end if;
 for q in select value from jsonb_array_elements(payload) loop
 if coalesce(length(trim(q->>'prompt')),0)=0 or jsonb_typeof(q->'choices') is distinct from 'array' or jsonb_array_length(q->'choices') not between 2 and 10 or jsonb_typeof(q->'correct') is distinct from 'string' or not(q->'choices' @> jsonb_build_array(q->'correct')) then raise exception 'راجعي الأسئلة والخيارات';end if;end loop;
 else payload:='[]';end if;
 f:=t.file_id;
 if p_data->>'p_base64' is not null then f:=hub_internal.fluency_file(p_data->>'p_mime',p_data->>'p_base64');end if;
 if p_data->>'skill'='listening' and not exists(select 1 from hub_internal.fluency_files where id=f and mime like 'audio/%') then raise exception 'أرفقي مقطع الاستماع';end if;
 if tid is null or p_op='copy' then
 insert into hub_internal.fluency_tasks(title,skill,level,prompt,questions,file_id,due_at,attempts) values(trim(p_data->>'title'),p_data->>'skill',p_data->>'level',p_data->>'prompt',payload,f,(p_data->>'due_at')::timestamptz,(p_data->>'attempts')::int) returning id into tid;
 else
 update hub_internal.fluency_tasks set title=trim(p_data->>'title'),level=p_data->>'level',prompt=p_data->>'prompt',questions=payload,file_id=f,due_at=(p_data->>'due_at')::timestamptz,attempts=(p_data->>'attempts')::int,revision=revision+1 where id=tid and skill=p_data->>'skill';
 if not found then raise exception 'المهارة غير متطابقة';end if;
 delete from hub_internal.fluency_targets where task_id=tid;
 end if;
 insert into hub_internal.fluency_targets select tid,unnest(targets);
 return to_jsonb(tid);
end $$;
revoke all on function hub_internal.fluency_file(text,text),hub_internal.fluency_progress(uuid),public.hub_fluency(text,jsonb,text) from public,anon,authenticated;
grant execute on function public.hub_fluency(text,jsonb,text) to anon,authenticated;
alter function public.hub_family(text,text,text) set schema hub_internal;
revoke all on function hub_internal.hub_family(text,text,text) from public,anon,authenticated;
create function public.hub_family(p_invite text,p_pin text,p_message text default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare data jsonb; sid uuid;
begin
 data:=hub_internal.hub_family(p_invite,p_pin,p_message);
 if data is null then return null;end if;
 select student_id into strict sid from public.parent_access where invite_hash=extensions.digest(p_invite,'sha256');
 return data||jsonb_build_object('fluency',hub_internal.fluency_progress(sid));
end $$;
revoke all on function public.hub_family(text,text,text) from public;
grant execute on function public.hub_family(text,text,text) to anon,authenticated;
alter function hub_internal.leadership_data() rename to leadership_base_data;
create function hub_internal.leadership_data() returns jsonb language sql stable set search_path='' as $$
 select hub_internal.leadership_base_data()||jsonb_build_object('fluency',hub_internal.fluency_progress(null))
$$;
revoke all on function hub_internal.leadership_data() from public,anon,authenticated;
