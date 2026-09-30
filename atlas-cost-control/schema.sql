-- =====================================================================
-- ATLAS COST CONTROL  —  Supabase database, version 1
-- Run this whole file once in Supabase > SQL Editor > New query > Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- MASTERS ----------
create table if not exists branches (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  category text,
  active boolean not null default true,
  created_at timestamptz default now()
);

create table if not exists departments (
  id uuid primary key default gen_random_uuid(),
  name text unique not null
);

create table if not exists profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text,
  email text,
  role text not null default 'pending'
    check (role in ('pending','md','admin','branch_manager','hod','hr','accounts','audit')),
  branch_id uuid references branches,
  department_id uuid references departments,
  created_at timestamptz default now()
);

-- basis:
--   monthly         daily target = monthly amount / days in month
--   per_staff       salary: actual = present staff x target cost per head (auto)
--   per_attendance  target flexes with attendance (e.g. food/mess)
--   sales_pct       target flexes with sales (e.g. incentive, bank charges)
create table if not exists expense_heads (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,
  type text not null check (type in ('fixed','variable')),
  basis text not null default 'monthly'
    check (basis in ('monthly','per_staff','per_attendance','sales_pct')),
  department_id uuid references departments,
  amber_pct numeric not null default 5,
  red_pct numeric not null default 10,
  bill_required_above numeric not null default 5000,
  sort int not null default 0,
  active boolean not null default true
);

-- ---------- TARGETS ----------
create table if not exists branch_month_targets (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches,
  month date not null,                       -- always the 1st of the month
  sales_target numeric not null default 0,   -- monthly sales target
  gp_pct_target numeric not null default 35,
  staff_target int not null default 0,
  ho_allocation numeric not null default 0,  -- monthly HO cost allocated to branch
  status text not null default 'draft' check (status in ('draft','pending','approved')),
  version int not null default 1,
  approved_by uuid references profiles,
  approved_at timestamptz,
  unique (branch_id, month)
);

create table if not exists branch_head_targets (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches,
  month date not null,
  expense_head_id uuid not null references expense_heads,
  monthly_amount numeric not null default 0,
  unique (branch_id, month, expense_head_id)
);

-- ---------- DAILY OPERATION ----------
create table if not exists daily_closings (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches,
  date date not null,
  staff_on_roll int default 0,
  present int default 0,
  on_leave int default 0,
  absent int default 0,
  sales numeric default 0,
  gp_pct numeric default 0,
  bills int default 0,
  remarks text,
  status text not null default 'draft' check (status in ('draft','submitted','reopen_requested')),
  submitted_by uuid references profiles,
  submitted_at timestamptz,
  unique (branch_id, date)
);

create table if not exists daily_expenses (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references branches,
  date date not null,
  expense_head_id uuid not null references expense_heads,
  amount numeric not null default 0,
  reason text,
  bill_path text,
  unique (branch_id, date, expense_head_id)
);

create table if not exists actions (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid references branches,
  expense_head_id uuid references expense_heads,
  date date default current_date,
  title text not null,
  variance numeric,
  owner_role text default 'branch_manager',
  due_date date,
  status text not null default 'open'
    check (status in ('open','in_progress','completed','verified','closed')),
  note text,
  created_by uuid references profiles default auth.uid(),
  created_at timestamptz default now()
);

create table if not exists audit_logs (
  id bigserial primary key,
  table_name text,
  row_id text,
  action text,
  old_data jsonb,
  new_data jsonb,
  user_id uuid default auth.uid(),
  at timestamptz default now()
);

create index if not exists idx_closing_date on daily_closings(date);
create index if not exists idx_exp_date on daily_expenses(date);
create index if not exists idx_audit_at on audit_logs(at desc);

-- ---------- HELPER FUNCTIONS (who is logged in) ----------
create or replace function my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() $$;

create or replace function my_branch() returns uuid
language sql stable security definer set search_path = public as
$$ select branch_id from profiles where id = auth.uid() $$;

create or replace function my_dept() returns uuid
language sql stable security definer set search_path = public as
$$ select department_id from profiles where id = auth.uid() $$;

create or replace function is_mgmt() returns boolean
language sql stable as
$$ select coalesce(my_role() in ('md','admin','accounts','audit'), false) $$;

create or replace function is_editor() returns boolean
language sql stable as
$$ select coalesce(my_role() in ('md','admin'), false) $$;

create or replace function head_in_my_dept(h uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from expense_heads where id = h and department_id = my_dept()) $$;

-- ---------- AUTO-CREATE PROFILE ON SIGN-UP ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, full_name)
  values (new.id, new.email, split_part(new.email, '@', 1))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function handle_new_user();

-- ---------- AUDIT TRAIL ----------
create or replace function log_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    insert into audit_logs(table_name,row_id,action,old_data,user_id)
    values (tg_table_name, old.id::text, tg_op, to_jsonb(old), auth.uid());
    return old;
  elsif tg_op = 'UPDATE' then
    insert into audit_logs(table_name,row_id,action,old_data,new_data,user_id)
    values (tg_table_name, new.id::text, tg_op, to_jsonb(old), to_jsonb(new), auth.uid());
    return new;
  else
    insert into audit_logs(table_name,row_id,action,new_data,user_id)
    values (tg_table_name, new.id::text, tg_op, to_jsonb(new), auth.uid());
    return new;
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['branches','departments','profiles','expense_heads',
    'branch_month_targets','branch_head_targets','daily_closings','daily_expenses','actions']
  loop
    execute format('drop trigger if exists audit_%1$s on %1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on %1$s
                    for each row execute function log_audit()', t);
  end loop;
end $$;

-- ---------- TARGET VERSIONING ----------
-- Changing an approved target creates a new version and sends it back for approval.
create or replace function bump_target_version() returns trigger
language plpgsql as $$
begin
  if old.status = 'approved' and new.status = 'approved'
     and (new.sales_target, new.gp_pct_target, new.staff_target, new.ho_allocation)
         is distinct from (old.sales_target, old.gp_pct_target, old.staff_target, old.ho_allocation)
  then
    new.version := old.version + 1;
    new.status := 'pending';
    new.approved_by := null;
    new.approved_at := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_bump_version on branch_month_targets;
create trigger trg_bump_version before update on branch_month_targets
for each row execute function bump_target_version();

-- ---------- ROW LEVEL SECURITY (backend enforces who sees what) ----------
alter table branches enable row level security;
alter table departments enable row level security;
alter table profiles enable row level security;
alter table expense_heads enable row level security;
alter table branch_month_targets enable row level security;
alter table branch_head_targets enable row level security;
alter table daily_closings enable row level security;
alter table daily_expenses enable row level security;
alter table actions enable row level security;
alter table audit_logs enable row level security;

-- masters: everyone logged in can read, only MD/Admin can change
create policy "read branches" on branches for select to authenticated using (true);
create policy "edit branches" on branches for all to authenticated using (is_editor()) with check (is_editor());
create policy "read departments" on departments for select to authenticated using (true);
create policy "edit departments" on departments for all to authenticated using (is_editor()) with check (is_editor());
create policy "read heads" on expense_heads for select to authenticated using (true);
create policy "edit heads" on expense_heads for all to authenticated using (is_editor()) with check (is_editor());

-- profiles: own profile, or MD/Admin/HR/Audit see all; only MD changes roles
create policy "read profiles" on profiles for select to authenticated
  using (id = auth.uid() or my_role() in ('md','admin','hr','audit'));
create policy "md edits profiles" on profiles for update to authenticated
  using (my_role() = 'md') with check (my_role() = 'md');

-- month targets
create policy "read month targets" on branch_month_targets for select to authenticated
  using (is_mgmt() or branch_id = my_branch() or my_role() in ('hod','hr'));
create policy "edit month targets" on branch_month_targets for all to authenticated
  using (is_editor()) with check (is_editor());

-- head targets: HOD can propose for own department's heads while month is in draft
create policy "read head targets" on branch_head_targets for select to authenticated
  using (is_mgmt() or branch_id = my_branch() or my_role() = 'hr'
         or (my_role() = 'hod' and head_in_my_dept(expense_head_id)));
create policy "edit head targets" on branch_head_targets for all to authenticated
  using (is_editor()) with check (is_editor());
create policy "hod insert head targets" on branch_head_targets for insert to authenticated
  with check (my_role() = 'hod' and head_in_my_dept(expense_head_id)
    and exists (select 1 from branch_month_targets t where t.branch_id = branch_head_targets.branch_id
                and t.month = branch_head_targets.month and t.status = 'draft'));
create policy "hod update head targets" on branch_head_targets for update to authenticated
  using (my_role() = 'hod' and head_in_my_dept(expense_head_id)
    and exists (select 1 from branch_month_targets t where t.branch_id = branch_head_targets.branch_id
                and t.month = branch_head_targets.month and t.status = 'draft'))
  with check (my_role() = 'hod' and head_in_my_dept(expense_head_id));

-- daily closings: branch manager only own branch, and only while draft
create policy "read closings" on daily_closings for select to authenticated
  using (is_mgmt() or branch_id = my_branch());
create policy "bm insert closing" on daily_closings for insert to authenticated
  with check (my_role() = 'branch_manager' and branch_id = my_branch() and status in ('draft','submitted'));
create policy "bm update draft closing" on daily_closings for update to authenticated
  using (my_role() = 'branch_manager' and branch_id = my_branch() and status = 'draft')
  with check (branch_id = my_branch() and status in ('draft','submitted'));
create policy "editors manage closings" on daily_closings for all to authenticated
  using (my_role() in ('md','admin','accounts')) with check (my_role() in ('md','admin','accounts'));

-- daily expenses: branch manager own branch while the day is not submitted; HOD reads own heads
create policy "read expenses" on daily_expenses for select to authenticated
  using (is_mgmt() or branch_id = my_branch()
         or (my_role() = 'hod' and head_in_my_dept(expense_head_id)));
create policy "bm write expenses" on daily_expenses for insert to authenticated
  with check (my_role() = 'branch_manager' and branch_id = my_branch()
    and not exists (select 1 from daily_closings c where c.branch_id = daily_expenses.branch_id
                    and c.date = daily_expenses.date and c.status <> 'draft'));
create policy "bm update expenses" on daily_expenses for update to authenticated
  using (my_role() = 'branch_manager' and branch_id = my_branch()
    and not exists (select 1 from daily_closings c where c.branch_id = daily_expenses.branch_id
                    and c.date = daily_expenses.date and c.status <> 'draft'))
  with check (branch_id = my_branch());
create policy "editors manage expenses" on daily_expenses for all to authenticated
  using (my_role() in ('md','admin','accounts')) with check (my_role() in ('md','admin','accounts'));

-- actions
create policy "read actions" on actions for select to authenticated
  using (is_mgmt() or branch_id = my_branch() or created_by = auth.uid()
         or (my_role() = 'hod' and head_in_my_dept(expense_head_id)));
create policy "create actions" on actions for insert to authenticated
  with check (my_role() in ('md','admin','hod') or (my_role() = 'branch_manager' and branch_id = my_branch()));
create policy "update actions" on actions for update to authenticated
  using (is_editor() or (my_role() = 'branch_manager' and branch_id = my_branch()) or created_by = auth.uid())
  with check (is_editor() or status in ('open','in_progress','completed'));

-- audit log: read only for MD/Admin/Audit (rows are written by the trigger)
create policy "read audit" on audit_logs for select to authenticated
  using (my_role() in ('md','admin','audit'));

-- HR / HOD attendance view: attendance columns only, no sales figures
create or replace view hr_attendance as
  select id, branch_id, date, staff_on_roll, present, on_leave, absent, status
  from daily_closings
  where my_role() in ('hr','hod','md','admin','accounts','audit');
grant select on hr_attendance to authenticated;

-- branch manager asks for a submitted day to be reopened
create or replace function request_reopen(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update daily_closings set status = 'reopen_requested'
  where id = p_id and branch_id = my_branch() and status = 'submitted';
end $$;

-- ---------- FILE STORAGE FOR BILLS ----------
insert into storage.buckets (id, name, public) values ('bills','bills', false)
on conflict (id) do nothing;

create policy "upload bills" on storage.objects for insert to authenticated
  with check (bucket_id = 'bills' and (is_editor() or (storage.foldername(name))[1] = my_branch()::text));
create policy "read bills" on storage.objects for select to authenticated
  using (bucket_id = 'bills' and (is_mgmt() or (storage.foldername(name))[1] = my_branch()::text));

-- =====================================================================
-- STARTER DATA  (edit names/codes if needed, then run)
-- =====================================================================
insert into departments (name) values
 ('HR'),('Accounts & Finance'),('Purchase'),('Sales'),('Marketing'),('Administration'),
 ('Operations'),('Inventory'),('Audit'),('IT'),('Security & CCTV'),('VM'),
 ('Social Media'),('Transportation'),('MD Office')
on conflict (name) do nothing;

insert into branches (code, name, category) values
 ('PMNA','Perinthalmanna','A'),('KLM','Kollam','A'),('KDKL','Kadakkal','A'),
 ('NLB','Nilambur','A'),('KDVL','Koduvalli','A'),('KTM','Kothamangalam','B'),
 ('PBVR','Perumbavoor','B'),('KADS','KADS','B'),('GSQ','Gandhisquare','C'),('MVPA','MVPA','C')
on conflict (code) do nothing;

insert into expense_heads (name, type, basis, department_id, amber_pct, red_pct, sort)
select v.name, v.type, v.basis, d.id, v.amber, v.red, v.sort
from (values
 ('Shop Rent','fixed','monthly','Administration',2,5,1),
 ('Staff Quarters Rent','fixed','monthly','Administration',2,5,2),
 ('Parking Rent','fixed','monthly','Administration',2,5,3),
 ('Salary','fixed','per_staff','HR',3,6,4),
 ('PF/ESI','fixed','monthly','HR',3,6,5),
 ('Security','fixed','monthly','Security & CCTV',3,8,6),
 ('Telephone/Internet','fixed','monthly','IT',5,10,7),
 ('Electricity','variable','monthly','Administration',5,10,8),
 ('Food/Mess','variable','per_attendance','Administration',5,10,9),
 ('Maintenance','variable','monthly','Administration',10,20,10),
 ('Water','variable','monthly','Administration',10,20,11),
 ('Travelling','variable','monthly','Operations',10,20,12),
 ('Bank Charges','variable','sales_pct','Accounts & Finance',5,10,13),
 ('Advertisement','variable','monthly','Marketing',5,10,14),
 ('Sales Incentive','variable','sales_pct','Sales',5,10,15)
) as v(name,type,basis,dept,amber,red,sort)
join departments d on d.name = v.dept
on conflict (name) do nothing;

-- After you create your own login (Authentication > Users > Add user), make yourself MD:
-- update profiles set role = 'md', full_name = 'Your name' where email = 'you@example.com';
