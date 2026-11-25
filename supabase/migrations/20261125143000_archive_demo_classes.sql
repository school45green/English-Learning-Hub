do $$
begin
  if (select count(*) from public.school_classes
      where name in ('أول ثانوي - تجريبي','ثالث ثانوي - تجريبي')) <> 2 then
    raise exception 'Expected two demo classes';
  end if;
  update public.school_classes set archived_at=coalesce(archived_at,now())
    where name in ('أول ثانوي - تجريبي','ثالث ثانوي - تجريبي');
end $$;

create or replace function public.hub_admin_summary()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role in ('principal','vice_principal')) then
    raise exception 'Forbidden';
  end if;
  return (
    with hidden_classes as (
      select id from public.school_classes where archived_at is not null
        and name in ('أول ثانوي - تجريبي','ثالث ثانوي - تجريبي')
    ), visible_students as (
      select * from public.students where class_id not in (select id from hidden_classes)
    )
    select jsonb_build_object(
      'classes',(select count(*) from public.school_classes where id not in (select id from hidden_classes)),
      'students',(select count(*) from visible_students where active),
      'activities',(select count(*) from public.activities a where a.published and (
        (not exists(select 1 from public.activity_targets t where t.activity_id=a.id)
          and not exists(select 1 from public.activity_student_targets t where t.activity_id=a.id))
        or exists(select 1 from public.activity_targets t where t.activity_id=a.id and t.class_id not in (select id from hidden_classes))
        or exists(select 1 from public.activity_student_targets t join visible_students s on s.id=t.student_id where t.activity_id=a.id)
      )),
      'submissions',(select count(*) from public.submissions r join visible_students s on s.id=r.student_id),
      'class_totals',(
        select coalesce(jsonb_agg(jsonb_build_object(
          'name',c.name,'course',c.course,
          'students',(select count(*) from visible_students s where s.class_id=c.id and s.active),
          'submissions',(select count(*) from public.submissions r join visible_students s on s.id=r.student_id where s.class_id=c.id),
          'plans',(select count(*) from public.hub_plans p join visible_students s on s.id=p.student_id where s.class_id=c.id),
          'completed_plans',(select count(*) from public.hub_plans p join visible_students s on s.id=p.student_id where s.class_id=c.id and p.completed)
        ) order by c.grade_level,c.name),'[]'::jsonb)
        from public.school_classes c where c.id not in (select id from hidden_classes)
      )
    )
  );
end $$;
