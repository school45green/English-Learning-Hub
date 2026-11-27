create table hub_internal.mirror_lessons (
 id text primary key, course text not null, unit int not null, unit_title text not null,
 week int not null, position int not null, title text not null, unique(course,week,position)
);
create table hub_internal.mirror_votes (
 lesson_id text references hub_internal.mirror_lessons not null,
 student_id uuid references public.students not null, feeling smallint not null check(feeling between 1 and 4),
 suggestion text check(length(suggestion)<=240), primary key(lesson_id,student_id)
);
create table hub_internal.mirror_notes (
 lesson_id text primary key references hub_internal.mirror_lessons,
 reflection text not null check(length(reflection)<=1000), action text not null check(length(action)<=1000)
);
alter table hub_internal.mirror_lessons enable row level security;
alter table hub_internal.mirror_votes enable row level security;
alter table hub_internal.mirror_notes enable row level security;
revoke all on hub_internal.mirror_lessons,hub_internal.mirror_votes,hub_internal.mirror_notes from public,anon,authenticated;
insert into hub_internal.mirror_lessons values
('mg1-w14-1','Mega Goal 1',5,'Did You Hurt Yourself?',14,1,'Listening'),
('mg1-w14-2','Mega Goal 1',5,'Did You Hurt Yourself?',14,2,'Pronunciation'),
('mg1-w14-3','Mega Goal 1',5,'Did You Hurt Yourself?',14,3,'About You'),
('mg1-w14-4','Mega Goal 1',5,'Did You Hurt Yourself?',14,4,'Conversation'),
('mg1-w15-1','Mega Goal 1',5,'Did You Hurt Yourself?',15,1,'Reading'),
('mg1-w15-2','Mega Goal 1',5,'Did You Hurt Yourself?',15,2,'Writing'),
('mg1-w15-3','Mega Goal 1',5,'Did You Hurt Yourself?',15,3,'Form'),
('mg1-w15-4','Mega Goal 1',5,'Did You Hurt Yourself?',15,4,'Project'),
('mg1-w16-1','Mega Goal 1',6,'Take My Advice',16,1,'Listen and Discuss'),
('mg1-w16-2','Mega Goal 1',6,'Take My Advice',16,2,'Pair Work'),
('mg1-w16-3','Mega Goal 1',6,'Take My Advice',16,3,'Grammar'),
('mg1-w16-4','Mega Goal 1',6,'Take My Advice',16,4,'Language in Context'),
('mg1-w17-1','Mega Goal 1',6,'Take My Advice',17,1,'Listening'),
('mg1-w17-2','Mega Goal 1',6,'Take My Advice',17,2,'Pronunciation'),
('mg1-w17-3','Mega Goal 1',6,'Take My Advice',17,3,'About You'),
('mg1-w17-4','Mega Goal 1',6,'Take My Advice',17,4,'Conversation'),
('mg1-w18-1','Mega Goal 1',6,'Take My Advice',18,1,'Reading'),
('mg1-w18-2','Mega Goal 1',6,'Take My Advice',18,2,'Writing'),
('mg1-w18-3','Mega Goal 1',6,'Take My Advice',18,3,'Form'),
('mg1-w18-4','Mega Goal 1',6,'Take My Advice',18,4,'Project'),
('mg3-w14-1','Mega Goal 3',5,'Do You Really Need It?',14,1,'Listening'),
('mg3-w14-2','Mega Goal 3',5,'Do You Really Need It?',14,2,'Pronunciation'),
('mg3-w14-3','Mega Goal 3',5,'Do You Really Need It?',14,3,'Vocabulary Building'),
('mg3-w14-4','Mega Goal 3',5,'Do You Really Need It?',14,4,'Reading'),
('mg3-w15-1','Mega Goal 3',5,'Do You Really Need It?',15,1,'Speaking'),
('mg3-w15-2','Mega Goal 3',5,'Do You Really Need It?',15,2,'Writing'),
('mg3-w15-3','Mega Goal 3',5,'Do You Really Need It?',15,3,'Form'),
('mg3-w15-4','Mega Goal 3',5,'Do You Really Need It?',15,4,'Project'),
('mg3-w16-1','Mega Goal 3',6,'The Gender Divide',16,1,'Listen and Discuss'),
('mg3-w16-2','Mega Goal 3',6,'The Gender Divide',16,2,'Pair Work'),
('mg3-w16-3','Mega Goal 3',6,'The Gender Divide',16,3,'Grammar'),
('mg3-w16-4','Mega Goal 3',6,'The Gender Divide',16,4,'Conversation'),
('mg3-w17-1','Mega Goal 3',6,'The Gender Divide',17,1,'Listening'),
('mg3-w17-2','Mega Goal 3',6,'The Gender Divide',17,2,'Pronunciation'),
('mg3-w17-3','Mega Goal 3',6,'The Gender Divide',17,3,'Vocabulary Building'),
('mg3-w17-4','Mega Goal 3',6,'The Gender Divide',17,4,'Reading'),
('mg3-w18-1','Mega Goal 3',6,'The Gender Divide',18,1,'Speaking'),
('mg3-w18-2','Mega Goal 3',6,'The Gender Divide',18,2,'Writing'),
('mg3-w18-3','Mega Goal 3',6,'The Gender Divide',18,3,'Form'),
('mg3-w18-4','Mega Goal 3',6,'The Gender Divide',18,4,'Project');

create function hub_internal.mirror_report() returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object(
  'counts',coalesce(v.counts,'[0,0,0,0]'::jsonb),'suggestions',coalesce(v.suggestions,'[]'::jsonb),
  'reflection',coalesce(n.reflection,''),'action',coalesce(n.action,'')
 ) order by l.course,l.week,l.position),'[]'::jsonb)
 from hub_internal.mirror_lessons l left join hub_internal.mirror_notes n on n.lesson_id=l.id
 left join lateral(
   select jsonb_build_array(count(*) filter(where feeling=1),count(*) filter(where feeling=2),
   count(*) filter(where feeling=3),count(*) filter(where feeling=4)) counts,
   jsonb_agg(suggestion order by suggestion) filter(where suggestion is not null) suggestions
   from hub_internal.mirror_votes where lesson_id=l.id
 ) v on true
$$;

create function public.hub_learning_mirror(p_op text,p_data jsonb default '{}',p_token text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare sid uuid; lesson text:=p_data->>'id'; book text; total int;
begin
 if p_token is null and hub_internal.learning_teacher() then
   if p_op='report' then return hub_internal.mirror_report(); end if;
   if p_op='notes' then
     insert into hub_internal.mirror_notes(lesson_id,reflection,action)
       values(lesson,trim(coalesce(p_data->>'reflection','')),trim(coalesce(p_data->>'action','')))
       on conflict(lesson_id) do update set reflection=excluded.reflection,action=excluded.action;
     return '{}';
   end if;
 end if;
 sid:=hub_internal.learning_student(p_token);
 select c.course into book from public.students s join public.school_classes c on c.id=s.class_id
   where s.id=sid and s.active and c.archived_at is null;
 if book is null then raise insufficient_privilege; end if;
 if p_op='lessons' then
   return (select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('voted',v.student_id is not null) order by l.week,l.position),'[]'::jsonb)
     from hub_internal.mirror_lessons l left join hub_internal.mirror_votes v on v.lesson_id=l.id and v.student_id=sid
     where l.course=book);
 end if;
 if not exists(select 1 from hub_internal.mirror_lessons where id=lesson and course=book) then raise insufficient_privilege; end if;
 if p_op='vote' then
   insert into hub_internal.mirror_votes(lesson_id,student_id,feeling) values(lesson,sid,(p_data->>'feeling')::smallint)
     on conflict(lesson_id,student_id) do nothing;
   return '{"voted":true}';
 elsif p_op='suggest' then
   update hub_internal.mirror_votes set suggestion=nullif(trim(p_data->>'suggestion'),'') where lesson_id=lesson and student_id=sid;
   get diagnostics total=row_count;
   if total<>1 then raise insufficient_privilege;end if;
   return '{}';
 end if;
 raise insufficient_privilege;
end $$;
revoke all on function hub_internal.mirror_report(),public.hub_learning_mirror(text,jsonb,text) from public,anon,authenticated;
grant execute on function public.hub_learning_mirror(text,jsonb,text) to anon,authenticated;

create or replace function hub_internal.leadership_data() returns jsonb language sql stable set search_path='' as $$
 select hub_internal.leadership_base_data()||jsonb_build_object('fluency',hub_internal.fluency_progress(null),'mirror',(select jsonb_agg(x-'suggestions' order by ord) from jsonb_array_elements(hub_internal.mirror_report()) with ordinality r(x,ord)))
$$;
