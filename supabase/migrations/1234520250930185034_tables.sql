-- 09-30-2025_init.sql
-- Initial schema + RLS policies for Hope Club backend

-- enable uuid helper
create extension if not exists pgcrypto;

-- ========== Tables (from dbschema.sql) ==========

-- People
create table if not exists students (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  grade text,
  dob date null,
  cohort text,
  active boolean default true,
  created_at timestamptz default now()
);

create table if not exists guardians (
  id uuid primary key default gen_random_uuid(),
  name text,
  email text unique
);

create table if not exists guardian_student (
  guardian_id uuid references guardians(id) on delete cascade,
  student_id uuid references students(id) on delete cascade,
  primary key (guardian_id, student_id)
);

-- Points economy
create table if not exists point_categories (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  min_value int not null default -10,
  max_value int not null default 20,
  is_active boolean default true,
  created_by uuid references auth.users(id)
);

create table if not exists point_events (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id),
  category_id uuid references point_categories(id),
  delta int not null,
  note text,
  event_time timestamptz default now(),
  created_by uuid references auth.users(id)
);

-- Incidents
create table if not exists incidents (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id),
  category text,
  severity text,
  note text,
  photo_url text,
  created_by uuid references auth.users(id),
  created_at timestamptz default now()
);

-- Store
create table if not exists store_items (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  cost int not null,
  stock int not null default 0,
  is_active boolean default true,
  created_by uuid references auth.users(id)
);

create table if not exists redemptions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id),
  item_id uuid references store_items(id),
  cost_at_tx int not null,
  redeemed_at timestamptz default now(),
  created_by uuid references auth.users(id)
);

-- Audit
create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor uuid references auth.users(id),
  action text not null,
  target_id uuid null,
  meta jsonb,
  at timestamptz default now()
);

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
