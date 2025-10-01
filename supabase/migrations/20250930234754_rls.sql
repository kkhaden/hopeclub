-- ========== Helper functions for RLS (convenience) ==========
-- These functions are simple wrappers to keep policies readable.

create or replace function auth_role()
returns text
language sql stable
as $$
  select coalesce(auth.jwt() ->> 'role', '')::text;
$$;

create or replace function auth_uid()
returns uuid
language sql stable
as $$
  select (auth.uid())::uuid;
$$;

-- Note: auth.jwt() usage assumes that JWT includes a 'role' claim. Adjust claim name if different.

-- ========== Row Level Security (enable + policies) ==========

-- ---- students ----
alter table students enable row level security;

-- Admins: full access
create policy students_admin_all on students
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- Staff: read and write (create/update) student records
create policy students_staff_select on students
  for select
  using (auth_role() in ('staff','admin'));

create policy students_staff_modify on students
  for insert, update, delete
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- Guardians: allow select on students if guardian is linked to that student via guardian_student
create policy students_guardian_select on students
  for select
  using (
    auth_role() = 'guardian' and exists (
      select 1 from guardian_student gs
      where gs.guardian_id = auth_uid() and gs.student_id = students.id
    )
  );

-- Students: (optional) allow a student to view their own profile if auth.uid() equals student.id
-- This works if you create auth.users rows where the user's id equals students.id (or otherwise map profiles).
create policy students_self_select on students
  for select
  using (auth_role() = 'student' and auth_uid() = students.id);

-- ---- guardians ----
alter table guardians enable row level security;

create policy guardians_admin_staff_select on guardians
  for select
  using (auth_role() in ('staff','admin'));

create policy guardians_admin_staff_modify on guardians
  for insert, update, delete
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- Guardians: allow guardian users to view their own record
create policy guardians_self_select on guardians
  for select
  using (auth_role() = 'guardian' and auth_uid() = guardians.id);

-- ---- guardian_student (join) ----
alter table guardian_student enable row level security;

create policy guardian_student_admin on guardian_student
  for all
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- Allow guardians to see their own links
create policy guardian_student_guardian_select on guardian_student
  for select
  using (auth_role() = 'guardian' and guardian_id = auth_uid());

-- ---- point_categories ----
alter table point_categories enable row level security;

create policy point_categories_admin on point_categories
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- Staff can view categories
create policy point_categories_staff_select on point_categories
  for select
  using (auth_role() in ('staff','admin'));

-- ---- point_events ----
alter table point_events enable row level security;

-- Admins full access
create policy point_events_admin on point_events
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- Staff may insert and view events (recording points)
create policy point_events_staff_insert on point_events
  for insert
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

create policy point_events_staff_select on point_events
  for select
  using (auth_role() in ('staff','admin'));

-- Guardians may view events for their linked students
create policy point_events_guardian_select on point_events
  for select
  using (
    auth_role() = 'guardian' and exists (
      select 1 from guardian_student gs where gs.guardian_id = auth_uid() and gs.student_id = point_events.student_id
    )
  );

-- Students: allow select for their own events if mapping exists (see notes)
create policy point_events_self_select on point_events
  for select
  using (auth_role() = 'student' and auth_uid() = point_events.student_id);

-- ---- incidents ----
alter table incidents enable row level security;

create policy incidents_admin on incidents
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

create policy incidents_staff_insert_select on incidents
  for insert, select
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- Guardians can view incidents for linked students
create policy incidents_guardian_select on incidents
  for select
  using (auth_role() = 'guardian' and exists (
    select 1 from guardian_student gs where gs.guardian_id = auth_uid() and gs.student_id = incidents.student_id
  ));

-- ---- store_items ----
alter table store_items enable row level security;

create policy store_items_admin on store_items
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- staff can create/edit items
create policy store_items_staff_modify on store_items
  for insert, update, delete
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- public read for catalog (allow anonymous/public select if you want the store catalog visible)
create policy store_items_public_select on store_items
  for select
  using (is_true(true)); -- allow all (you can change to staff/admin only)

-- ---- redemptions ----
alter table redemptions enable row level security;

create policy redemptions_admin on redemptions
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- staff can create redemption rows on behalf of students
create policy redemptions_staff_insert on redemptions
  for insert
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));

-- students may view their own redemptions (if mapping exists)
create policy redemptions_self_select on redemptions
  for select
  using (auth_role() = 'student' and auth_uid() = redemptions.student_id);

-- guardians may view redemptions for linked students
create policy redemptions_guardian_select on redemptions
  for select
  using (auth_role() = 'guardian' and exists (
    select 1 from guardian_student gs where gs.guardian_id = auth_uid() and gs.student_id = redemptions.student_id
  ));

-- ---- audit_logs ----
alter table audit_logs enable row level security;

-- Audit logs should be admin-only by default
create policy audit_logs_admin on audit_logs
  for all
  using (auth_role() = 'admin')
  with check (auth_role() = 'admin');

-- Optionally allow staff to insert audit rows (if application writes them with staff identity)
create policy audit_logs_staff_insert on audit_logs
  for insert
  using (auth_role() in ('staff','admin'))
  with check (auth_role() in ('staff','admin'));
