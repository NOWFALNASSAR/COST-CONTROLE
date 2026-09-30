# Atlas Cost Control — build and launch guide

Everything here is done in a web browser. No laptop software needed.

**What's in this folder**

- `index.html` — the whole app (screens, calculations, alerts, WhatsApp report)
- `schema.sql` — the database: tables, security rules, audit trail, starter data
- `GUIDE.md` — this guide

The app runs in **demo mode** until you paste your Supabase keys into `index.html`. Demo mode is safe for showing the team.

---

## Stage 1 — Create the database (Supabase) · 15 minutes

1. Go to supabase.com → **New project**. Name it `atlas-cost-control`. Region: **Mumbai (ap-south-1)**. Save the database password somewhere safe.
2. Wait until the project finishes setting up.
3. Left menu → **SQL Editor** → **New query**.
4. Open `schema.sql`, copy everything, paste, press **Run**. You should see "Success. No rows returned."
5. Check: left menu → **Table Editor**. You should see `branches` (10 rows), `departments` (15), `expense_heads` (15).

If a branch name or code is wrong, edit it directly in Table Editor now.

## Stage 2 — Create your MD login · 5 minutes

1. Left menu → **Authentication** → **Users** → **Add user** → **Create new user**. Enter your email and a password. Tick **Auto confirm user**.
2. Go back to **SQL Editor**, run (with your email):

```sql
update profiles set role = 'md', full_name = 'Nowfal' where email = 'you@example.com';
```

3. Check: Table Editor → `profiles` → your row shows role `md`.

## Stage 3 — Connect the app to the database · 5 minutes

1. Supabase → **Project Settings** → **API**. Copy two things:
   - **Project URL** (looks like `https://abcd1234.supabase.co`)
   - **anon public** key (under "Project API keys"; if you see the new key screen, open the **Legacy API keys** tab and copy `anon`)
2. Open `index.html` in any text editor (or directly in GitHub, Stage 4). Near the top of the script find:

```js
const SUPABASE_URL = "";
const SUPABASE_ANON_KEY = "";
```

3. Paste your values between the quotes. Save.

The anon key is designed to be public. Data is protected by the security rules in `schema.sql`, which run inside the database, so a branch manager can never pull another branch's data, even with technical tricks.

## Stage 4 — Put it online (GitHub + Vercel) · 10 minutes

1. GitHub → **New repository** → name `atlas-cost-control` → **Private** → Create.
2. Click **uploading an existing file** → drag in `index.html` → **Commit changes**.
3. Vercel → **Add New → Project** → import `atlas-cost-control`. Framework preset: **Other**. Leave build settings empty. **Deploy**.
4. Open the Vercel link. You'll see the sign-in screen. Sign in with your MD login.
5. Optional: Vercel → Project → **Settings → Domains** → add `cost.yourdomain.com`.

From now on, any change you commit to `index.html` on GitHub goes live automatically within a minute.

## Stage 5 — Set up the month · 30–60 minutes (first time)

1. Sign in as MD → **Masters**.
   - Check each expense head: Fixed or Variable, target basis, responsible department, amber/red thresholds, bill limit.
   - Target basis meanings:
     - *monthly* — daily target = monthly ÷ days in month (rent, electricity)
     - *per staff* — salary; actual is calculated as present staff × cost per head
     - *per attendance* — target moves with attendance (food/mess)
     - *sales pct* — target moves with sales (incentive, bank charges)
2. **Targets** → pick each branch → enter from your ATLESS COST CONTROL SHEET:
   - Monthly sales target, GP % target, staff target, HO allocation
   - Monthly amount for every expense head
   - Press **Save**, then **Approve**.
3. From next month onward use **Copy last month**, adjust, approve.

The app divides by the real number of days (30, 31, 28/29), so you never change the formula.

## Stage 6 — Add your team · 20 minutes

For each person:

1. Supabase → Authentication → **Add user** (their email + a starting password, auto confirm).
2. In the app → **Masters → Users and rights** → set:
   - Branch managers → role *Branch manager* + their branch
   - HODs → role *Head of department* + their department
   - HR, Accounts, Audit, Admin → the matching role
3. Press **Save** on each row. Share the link and password on WhatsApp. They can change password later (Stage 8 adds a button).

## Stage 7 — Pilot, then roll out · 2 weeks

- Week 1: **Perinthalmanna and Kollam only**. Branch managers submit daily closing from their phones before 11 PM. Admin checks **Daily closings** every morning.
- Fix any expense heads or thresholds that give wrong alerts.
- Week 2: all branches. MD watches **Company**, **Departments** and **Action center** daily.

Rule to announce: *any head in red must have a reason; any repeated red gets an action with an owner and due date.*

## Stage 8 — Next phases (build one at a time)

| Phase | Add | How |
|---|---|---|
| 2 | Employee-level attendance | New `employees` and `attendance` tables; closing reads present count from them |
| 2 | Expense approval limits (₹5K / ₹25K / ₹1L) | `approval_limits` table + approval screen for Admin/Accounts/MD |
| 3 | Sales from billing software | Your billing is already connected to your MIS app — write a nightly job (Supabase Edge Function or cron) that fills `daily_closings.sales / gp_pct / bills`. Managers only confirm |
| 3 | HO department own costs | `department_month_targets` + `daily_department_actuals` tables, same screens |
| 4 | WhatsApp auto-report | Edge Function at 11:15 PM sends the same text as the *WhatsApp report* button via WhatsApp Business API |
| 4 | AI commentary | Edge Function sends the day's calculated numbers (never raw data for AI to calculate) to an AI model and stores a 3-line explanation |
| 4 | Password change, Excel/PDF export | Supabase `auth.updateUser`, SheetJS export |

## When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| App still shows "Demo data" | Keys not saved | Check Stage 3, commit again |
| "Profile not found" after login | User created before `schema.sql` was run | SQL: `insert into profiles(id,email) select id,email from auth.users on conflict do nothing;` |
| "Waiting for role" screen | Role not assigned | MD sets it in Masters |
| "new row violates row-level security" | User doing something their role can't | Correct — check the role, or the day is already submitted (request correction) |
| Branch manager sees no data | Branch not set on their profile | Masters → Users → set branch |
| Numbers look wrong for a branch | Target missing or head basis wrong | Targets screen + Masters |

## Backup

Supabase → Database → **Backups** (daily on paid plans). On the free plan, export key tables monthly: Table Editor → table → **Export to CSV**.
