alter table public.activities add column quiz_closed boolean not null default false,
  add column quiz_removed boolean not null default false, add column quiz_revision integer not null default 0;
update public.activities a set quiz_closed=true where not published and
  (exists(select 1 from public.submissions s where s.activity_id=a.id) or exists(select 1 from hub_internal.activity_drafts d where d.activity_id=a.id));

create function hub_internal.track_quiz_state() returns trigger language plpgsql set search_path='' as $$
begin
  if new.quiz_removed and new.published then raise exception 'الاختبار محذوف'; end if;
  if new.published then new.quiz_closed:=false;
  elsif old.published then new.quiz_closed:=true; end if;
  new.quiz_revision:=old.quiz_revision+1;
  return new;
end $$;
create trigger track_quiz_state before update on public.activities for each row execute function hub_internal.track_quiz_state();

create function public.hub_manage_quiz(p_id uuid,p_action text,p_revision integer,p_questions jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.activities%rowtype; q jsonb; total integer:=0; new_id uuid;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise insufficient_privilege; end if;
  select * into strict a from public.activities where id=p_id and not quiz_removed for update;
  if a.quiz_revision is distinct from p_revision then raise exception 'تغير الاختبار. أعيدي فتح القسم.'; end if;
  if p_action='read' then return coalesce(a.answer_key->'questions','[]'); end if;
  if p_action='delete' then
    update public.activities set published=false,quiz_removed=true where id=p_id;
    return '{}';
  end if;
  if p_action is distinct from 'edit' then raise exception 'Unknown operation'; end if;
  if jsonb_typeof(p_questions) is distinct from 'array' or jsonb_array_length(p_questions) not between 1 and 100 then raise exception 'راجعي عدد الأسئلة'; end if;
  for q in select value from jsonb_array_elements(p_questions) loop
    if coalesce(length(trim(q->>'prompt')),0)=0 or jsonb_typeof(q->'choices') is distinct from 'array'
      or jsonb_array_length(q->'choices') not between 2 and 10 or not coalesce(q->'choices' @> jsonb_build_array(q->'correct'),false)
      or coalesce((q->>'points')::integer,0) not between 1 and 20 then raise exception 'راجعي الخيارات والإجابة والدرجة'; end if;
    total:=total+(q->>'points')::integer;
  end loop;
  if (select count(distinct value->>'id') from jsonb_array_elements(p_questions))<>jsonb_array_length(p_questions) then raise exception 'معرّفات الأسئلة غير صالحة'; end if;
  if a.published or a.quiz_closed or exists(select 1 from public.submissions where activity_id=p_id) or exists(select 1 from hub_internal.activity_drafts where activity_id=p_id) then
    insert into public.activities(title,kind,course,unit_no,skill,max_score,max_attempts,answer_key,published)
      values(a.title,a.kind,a.course,a.unit_no,a.skill,total,a.max_attempts,jsonb_build_object('questions',p_questions),false) returning id into new_id;
    insert into public.activity_targets(activity_id,class_id) select new_id,class_id from public.activity_targets where activity_id=p_id;
    insert into public.activity_student_targets(activity_id,student_id) select new_id,student_id from public.activity_student_targets where activity_id=p_id;
    update public.activities set published=false,quiz_closed=true where id=p_id;
  else
    update public.activities set answer_key=jsonb_build_object('questions',p_questions),max_score=total where id=p_id;
  end if;
  return jsonb_build_object('versioned',new_id is not null);
end $$;
revoke all on function public.hub_manage_quiz(uuid,text,integer,jsonb) from public,anon,authenticated;
grant execute on function public.hub_manage_quiz(uuid,text,integer,jsonb) to authenticated;
