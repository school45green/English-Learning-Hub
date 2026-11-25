alter table public.school_classes add column archived_at timestamptz;

create function public.hub_manage_class(p_id uuid,p_name text,p_grade text,p_archive boolean default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_course text; v_current public.school_classes%rowtype;
begin
 if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'الصلاحية للمعلمة'; end if;
 if p_id is not null then
  select * into strict v_current from public.school_classes where id=p_id for update;
 end if;
 if p_archive is not null then
  if p_id is null then raise exception 'اختاري فصلًا'; end if;
  if p_archive and exists(select 1 from public.students where class_id=p_id and active) then
    raise exception 'أوقفي أو انقلي الطالبات النشطات قبل أرشفة الفصل';
  end if;
  update public.school_classes set archived_at=case when p_archive then coalesce(archived_at,now()) end where id=p_id;
  return p_id;
 end if;
 v_course:=case p_grade when 'أول ثانوي' then 'Mega Goal 1' when 'ثالث ثانوي' then 'Mega Goal 3' end;
 if v_course is null or p_name is null or length(btrim(p_name)) not between 1 and 100 then raise exception 'بيانات الفصل غير صالحة'; end if;
 if p_id is null then
   insert into public.school_classes(name,course,grade_level) values(btrim(p_name),v_course,p_grade) returning id into v_id;
   return v_id;
 end if;
 if v_current.course<>v_course and exists(select 1 from public.activity_targets where class_id=p_id) then
   raise exception 'الفصل مرتبط بأنشطة في المقرر الحالي';
 end if;
 update public.school_classes set name=btrim(p_name),grade_level=p_grade,course=v_course where id=p_id;
 return p_id;
end $$;

create function public.hub_guard_student_class()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.active then
   perform 1 from public.school_classes c where c.id=new.class_id and c.archived_at is null for share;
   if not found then raise exception 'الفصل مؤرشف أو غير موجود'; end if;
 end if;
 return new;
end $$;
create trigger hub_guard_student_class before insert or update of class_id,active on public.students
for each row execute function public.hub_guard_student_class();

create function public.hub_import_roster(p_class uuid,p_names text[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_added integer; v_requested integer;
begin
 if not exists(select 1 from public.staff_roles where user_id=auth.uid() and role='teacher') then raise exception 'الصلاحية للمعلمة'; end if;
 if coalesce(cardinality(p_names),0) not between 1 and 500 then raise exception 'الحد من اسم واحد إلى 500 اسم'; end if;
 if exists(select 1 from unnest(p_names) n where n is null or length(btrim(n)) not between 2 and 160 or n ~ '[[:cntrl:]]') then raise exception 'راجعي الأسماء في الملف'; end if;
 perform 1 from public.school_classes where id=p_class and archived_at is null for share;
 if not found then raise exception 'الفصل مؤرشف أو غير موجود'; end if;
 with names as (
   select distinct regexp_replace(btrim(n),'[[:space:]]+',' ','g') name from unnest(p_names) n
 ), created as (
   insert into public.students(full_name,class_id) select name,p_class from names
   on conflict(full_name,class_id) do nothing returning id
 )
 select (select count(*) from names),(select count(*) from created) into v_requested,v_added;
 return jsonb_build_object('added',v_added,'existing',v_requested-v_added,
                           'duplicates',cardinality(p_names)-v_requested);
end $$;

create or replace function public.hub_login_classes()
returns table(id uuid,name text,grade_level text) language sql stable security definer set search_path='' as $$
select c.id,c.name,c.grade_level from public.school_classes c
where c.name not like '%تجريبي%' and c.archived_at is null
order by c.grade_level,c.name
$$;
revoke all on function public.hub_manage_class(uuid,text,text,boolean),public.hub_guard_student_class(),
  public.hub_import_roster(uuid,text[]) from public,anon,authenticated;
grant execute on function public.hub_manage_class(uuid,text,text,boolean),public.hub_import_roster(uuid,text[]) to authenticated;
