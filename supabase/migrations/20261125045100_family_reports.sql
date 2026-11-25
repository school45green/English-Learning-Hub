-- Preserve legacy invitations and issue new class invitations only when needed.
create or replace function public.hub_issue_family(p_student_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_pin text; v_invite text;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  perform 1 from public.students where id=p_student_id and active for update;
  if not found then raise exception 'Student unavailable'; end if;
  select public.teacher_issue_parent_pin(p_student_id) into v_pin;
  select public.hub_set_family_invite(p_student_id) into v_invite;
  return jsonb_build_object('pin',v_pin,'invite',v_invite);
end $$;

create function public.hub_issue_class_family(p_class uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare student record; issued jsonb; invitations jsonb:='[]'::jsonb;
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'Forbidden'; end if;
  if not exists(select 1 from public.school_classes where id=p_class) then raise exception 'Class not found'; end if;
  for student in select id,full_name from public.students where class_id=p_class and active order by id for update loop
    if not exists(select 1 from public.parent_access where student_id=student.id and revoked_at is null and expires_at>now()) then
      issued:=public.hub_issue_family(student.id);
      invitations:=invitations||jsonb_build_array(issued||jsonb_build_object('name',student.full_name));
    end if;
  end loop;
  return invitations;
end $$;
revoke all on function public.hub_issue_class_family(uuid) from public,anon,authenticated;
grant execute on function public.hub_issue_class_family(uuid) to authenticated;

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

-- Administrative roles receive class totals and cannot write school records.
create or replace function public.hub_admin_summary()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role in ('principal','vice_principal')) then
    raise exception 'Forbidden';
  end if;
  return jsonb_build_object(
    'classes',(select count(*) from public.school_classes),
    'students',(select count(*) from public.students where active),
    'activities',(select count(*) from public.activities where published),
    'submissions',(select count(*) from public.submissions),
    'class_totals',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'name',c.name, 'course',c.course,
        'students',(select count(*) from public.students s where s.class_id=c.id and s.active),
        'submissions',(select count(*) from public.submissions r join public.students s on s.id=r.student_id where s.class_id=c.id),
        'plans',(select count(*) from public.hub_plans p join public.students s on s.id=p.student_id where s.class_id=c.id),
        'completed_plans',(select count(*) from public.hub_plans p join public.students s on s.id=p.student_id where s.class_id=c.id and p.completed)
      ) order by c.grade_level,c.name),'[]'::jsonb)
      from public.school_classes c
    )
  );
end $$;
