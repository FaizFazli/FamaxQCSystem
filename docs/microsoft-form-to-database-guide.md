# Microsoft Form → Database — Setup Guide

How to get production daily output, keyed in on a phone through a Microsoft Form,
into the FamaxQCSystem database automatically. Written for someone doing this for
the first time.

Work through the sections in order. Sections 1–3 are done before you touch Power
Automate at all, and each one can be checked on its own before you move on.

**Roughly how long:** section 2 is five minutes, section 4 is the long pole
(installing the gateway, plus whatever it takes to get the SSL setting right).

---

## 0. What you are building

```
Microsoft Form  (operator's phone)
  |
  |  existing flow — already working, do not touch
  v
SharePoint list "PRODUCTION DAILY OUTPUT"
  |
  |  NEW flow — you build this in section 6
  v
On-premises data gateway  (on the server, outbound only)
  |
  v
Postgres 192.168.0.5:5432  ->  table form_daily_output
                                  |
                                  +-- trigger fills in part number,
                                      process and output count
```

**Why a gateway and not just an HTTP call.** The database sits on the factory LAN
at `192.168.0.5`. Power Automate runs in Microsoft's cloud and cannot dial into
your network. The gateway solves this by running on your server and making an
**outbound** connection to Microsoft. Nothing is exposed to the internet, no
router ports are forwarded, and no firewall holes are opened.

### Before you start, make sure you have

- [ ] **Power Automate premium** on the tenant. The PostgreSQL connector is a
      premium connector and only works through a gateway.
- [ ] **Administrator access to the server** `192.168.0.5` (to install the gateway).
- [ ] **The Postgres password** for the Supabase database on that server.
- [ ] **Edit rights** on the Microsoft Form and on the SharePoint site
      `famaxtechmy.sharepoint.com/sites/FamaxProduction`.

---

## 1. Fix the Form first

**Do this before anything else.** The Form as it stands may not collect enough to
identify what was produced, and it is far easier to fix now than after responses
are flowing.

### The Form MUST ask for the process

This was measured against the live `JobOrder` table (1072 rows, 167 job orders):

| If the operator gives you... | can you work out... | how often |
|---|---|---|
| JO number only | the part | 130 of 167 (78%) |
| JO number only | **the process** | **28 of 167 (17%)** |
| JO number + process | the part | 794 of 889 (89%) |
| the part name | **the part number** | **256 of 256 (100%)** |

A job order is a batch covering several parts, each routed through the same list
of processes. `JO/171125/01328` alone spans TURNING 1, 2, 3, 4 and MILLING 2.
`JO/081225/01358` at TURNING 1 covers three different parts.

So **the process cannot be guessed** — 83% of job orders have more than one. If
the Form does not ask, the response arrives unusable.

### The questions the Form needs

| Question | Required? | Notes |
|---|---|---|
| Production date | Yes | For a **night shift, the date the shift STARTED** — see the warning below |
| Shift | Yes | Choice: `Day` / `Night` |
| Operator | Yes | |
| JO number | Yes | e.g. `JO/171125/01328`. Punctuation and case do not matter |
| **Process** | **Yes** | e.g. `TURNING 1`. Cannot be derived |
| Part name | Recommended | Makes the match exact instead of 89%. Only needed when one JO covers several parts |
| Machine no | Optional | |
| Counter start | Yes | |
| Counter end | Yes | |
| Reject qty | Yes | |
| Remark | Optional | |

**Do not** add questions for part number or daily output — the database fills
both in (output = counter end − counter start − reject qty, floored at zero, the
same rule the `daily_output.html` page uses).

> ### ⚠️ The night shift trap
>
> A night shift runs 19:00–05:00 and is recorded against **the date it started**.
> Word the question so an operator finishing at 05:00 on the 18th enters the
> **17th**. If people enter the date they happened to be filling the form in, the
> numbers will not line up with the `Daily_Output` figures from the shop-floor PCs
> and nobody will be able to tell which is wrong.

Make the process question a **Choice** rather than free text if you can — pick the
process names from the list the shop floor actually uses (`TURNING 1`, `MILLING`,
`CUTTING`, `PLATING`, `BROACHING`, `WIRECUT`, `HARDEN`, and so on). It removes a
whole class of typos.

### Then check the SharePoint column names

After changing the Form, open the list → **Settings → List settings** → click each
column and read the `Field=` value at the end of the browser's address bar. That
is the **internal** name, which is what Power Automate uses, and it is not the
name you see on screen — SharePoint writes a space as `_x0020_`, so "Part Name"
becomes `Part_x0020_Name`.

Write the internal names down. You need them in section 6.

---

## 2. Create the table in the database

Run this **on the server** `192.168.0.5`, from the repo folder:

```
docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < sql/2026-08-17_form_daily_output.sql
```

It is safe to run more than once — it creates nothing twice and changes no
existing row.

### Check it worked

```
docker exec -it supabase-db psql -U supabase_admin -d postgres
```

```sql
\d form_daily_output
select count(*) from form_daily_output;                        -- 0
select tablename, policyname from pg_policies
 where tablename = 'form_daily_output';                        -- 2 rows
```

If `\d form_daily_output` shows the table and you see two policies, this section
is done.

---

## 3. Test the matching before you build anything

This is the step people skip and then spend a day debugging a flow that was never
the problem. It takes two minutes and proves the database half works on its own.

Still in `psql`, paste these one at a time. They use real job orders from your
live data.

```sql
-- A. Exact: JO + process. Should return the part, the part number,
--    output_count 145, and match_status 'matched'.
insert into form_daily_output (sp_item_id, jo_number, process,
                               counter_start, counter_end, reject_qty)
     values ('t1', 'JO/171125/01328', 'TURNING 1', 100, 250, 5);
select part_name, part_number, process, output_count, match_status
  from form_daily_output where sp_item_id = 't1';

-- B. Sloppy typing must still match. Same result as A.
insert into form_daily_output (sp_item_id, jo_number, process)
     values ('t2', 'jo 171125 01328', 'turning 1');
select part_name, match_status from form_daily_output where sp_item_id = 't2';

-- C. No process given, and this JO has five. Should be 'ambiguous'
--    with process left empty — it must not invent one.
insert into form_daily_output (sp_item_id, jo_number)
     values ('t3', 'JO/171125/01328');
select part_name, process, match_status from form_daily_output where sp_item_id = 't3';

-- D. A JO+process covering three parts -> 'ambiguous' until the part is named.
insert into form_daily_output (sp_item_id, jo_number, process)
     values ('t4', 'JO/081225/01358', 'TURNING 1');
select part_name, match_status from form_daily_output where sp_item_id = 't4';   -- ambiguous

insert into form_daily_output (sp_item_id, jo_number, process, part_name)
     values ('t5', 'JO/081225/01358', 'TURNING 1', 'DISQUE (K315D.08)');
select part_number, match_status from form_daily_output where sp_item_id = 't5'; -- matched

-- E. A process this JO does not have -> 'conflict', and the operator's
--    typed value is KEPT, not overwritten.
insert into form_daily_output (sp_item_id, jo_number, process)
     values ('t6', 'JO/171125/01328', 'ANODISING');
select process, match_status from form_daily_output where sp_item_id = 't6';

-- F. Nonsense JO -> 'no_jo'.
insert into form_daily_output (sp_item_id, jo_number) values ('t7', 'NOSUCHJO');
select match_status from form_daily_output where sp_item_id = 't7';

-- Clean up.
delete from form_daily_output
 where sp_item_id in ('t1','t2','t3','t4','t5','t6','t7');
```

**What the four statuses mean**, because you will see them on real data:

| `match_status` | Meaning | What to do |
|---|---|---|
| `matched` | Job order found, part and process both known | Nothing |
| `ambiguous` | Job order found, but what was given does not narrow it to one part or process | Usually means the Form did not collect the process or part |
| `conflict` | Job order found, but the operator named a part or process it does not carry | Somebody typed the wrong thing — the typed value is kept so you can see what |
| `no_jo` | No job order matches | Usually a response that arrived before the office created the JO. See section 9 |

---

## 4. Install the on-premises data gateway

On the server `192.168.0.5`.

1. Download the **on-premises data gateway** from
   <https://powerautomate.microsoft.com/en-us/data-gateway/>.
2. Run the installer. Choose **on-premises data gateway (recommended)** — *not*
   "personal mode". Personal mode only works for Power BI.
3. Sign in with a work account that has Power Platform rights.
4. Choose **Register a new gateway on this computer**.
5. Give it a name you will recognise (e.g. `FAMAX-SERVER-GW`) and set a
   **recovery key**.

> **Write the recovery key down and keep it somewhere safe.** It is the only way
> to move or restore the gateway later, and it cannot be recovered from Microsoft.

6. Confirm the gateway shows **Online** in the gateway app.

### If your firewall blocks outbound traffic

The gateway needs **outbound** TCP on 443, 5671, 5672 and 9350–9354. It needs
**no inbound ports at all** — if someone asks you to forward a port, the answer is
no, that is not how this works.

---

## 5. Create the database connection in Power Automate

1. Go to <https://make.powerautomate.com> → **Data → Connections → + New connection**.
2. Search for **PostgreSQL** and select it.
3. Fill in:

   | Field | Value |
   |---|---|
   | Authentication type | Basic |
   | Server | `localhost:5432` (the gateway is on the same machine as Postgres) |
   | Database | `postgres` |
   | Username | your Postgres user |
   | Password | your Postgres password |
   | Gateway | the gateway you registered in section 4 |

4. Click **Create**.

> ### The connection test usually fails the first time
>
> The gateway's PostgreSQL driver often insists on SSL, and the Supabase Postgres
> in Docker may not present a certificate it accepts. If you get an SSL or
> certificate error, change the **encryption / SSL mode** setting on the
> connection and try again. This is the single most common place to get stuck —
> it is a settings problem, not a password problem, so do not go round in circles
> re-typing the password.

---
Dai
## 6. Build the flow

1. **make.powerautomate.com → + Create → Automated cloud flow.**
2. Name it something like `Daily Output — SharePoint to Database`.
3. Trigger: search **SharePoint** → **When an item is created**. Create.
4. Fill the trigger in:
   - **Site Address:** `https://famaxtechmy.sharepoint.com/sites/FamaxProduction`
   - **List Name:** `PRODUCTION DAILY OUTPUT`
5. **+ New step** → search **PostgreSQL** → **Insert row**.
6. **Table name:** `public.form_daily_output`.
7. Map the fields as below.

### Field mapping

Fill the middle column from the internal names you wrote down in section 1.

| Table column | Your SharePoint column | Value to use |
|---|---|---|
| `sp_item_id` | — | dynamic content **ID** from the trigger |
| `sp_created_at` | — | dynamic content **Created** |
| `sp_created_by` | — | **Created by Email** (or Display Name) |
| `production_date` | Production date | the date column |
| `shift` | Shift | |
| `operator` | Operator | |
| `jo_number` | JO number | |
| `process` | Process | |
| `part_name` | Part name | leave blank if the Form does not ask |
| `machine_no` | Machine no | |
| `counter_start` | Counter start | see the number note below |
| `counter_end` | Counter end | see the number note below |
| `reject_qty` | Reject qty | see the number note below |
| `remark` | Remark | |

**Leave these completely empty** — the database fills them in, and anything you
put here will be treated as the operator asserting a value:

`part_number`, `output_count`, `match_status`, `matched_at`, `review_status`,
`ingested_at`, `raw`

### Numbers arrive as text — guard the blanks

SharePoint hands numbers over as text, and an empty answer is an empty string.
`float('')` throws and fails the whole run. For each of the three number fields,
use the **Expression** tab rather than picking the dynamic content directly:

```
if(empty(triggerOutputs()?['body/CounterStart']), null, float(triggerOutputs()?['body/CounterStart']))
```

Replace `CounterStart` with your actual internal column name each time.

> ### ⚠️ Do not convert the production date
>
> Do not wrap `production_date` in anything that changes its time zone.
> SharePoint stores times in UTC and Malaysia is UTC+8, so a night-shift entry
> submitted after 20:00 converts back to the **previous day**. Pass the date the
> operator picked through exactly as it is. Only `sp_created_at` should be UTC.

8. **Save**, then turn the flow **off** for now — you want the backfill (section 7)
   to run first.

### Optional: stop duplicate rows creating failed runs

You do not strictly need this. `sp_item_id` is the primary key, so a duplicate is
rejected by the database and no bad data can get in — the run just shows as
failed. If you would rather keep the run history clean:

- Between the trigger and **Insert row**, add **PostgreSQL → Get rows** on
  `public.form_daily_output` with **Filter Query** `sp_item_id eq '<ID>'`.
- Then a **Condition**: `length(body('Get_rows')?['value'])` **is equal to** `0`.
- Move **Insert row** into the **If yes** branch.

---

## 7. Load the responses already in the list

The SharePoint list already has responses in it. Bring them in once, **before**
turning the live flow on, so nothing is counted twice.

1. **+ Create → Instant cloud flow** → trigger **Manually trigger a flow**.
   Name it `Daily Output — one-off backfill`.
2. **+ New step** → **SharePoint → Get items**:
   - Same site and list.
   - Under **Settings** (the "…" menu on the action), turn **Pagination on** and
     set the threshold above your current item count (e.g. `5000`).
3. **+ New step** → **PostgreSQL → Insert row**, mapped exactly as in section 6 —
   but the dynamic content now comes from **Get items** rather than the trigger.
   Power Automate wraps it in an **Apply to each** automatically.
4. On the **Apply to each**, open **Settings** → turn **Concurrency Control** on
   and set the degree to about **5**, so the gateway is not swamped.
5. **Save**, then **Test → Manually → Run**.

### Then check the count matches

```sql
select count(*) from form_daily_output;
```

Compare against the item count SharePoint shows at the foot of the list. They
should be equal.

Run the backfill a second time — the count **must not change**. That proves the
primary key is doing its job and that a re-run can never duplicate anything.

6. Now go back and turn the **live flow from section 6 on**.

---

## 8. End-to-end check

Work down this list. Stop at the first thing that fails.

- [ ] Add a test item **directly in the SharePoint list**. Within a minute a row
      appears in `form_daily_output`.
- [ ] The types are right — `production_date` is a real date, `counter_end` is a
      number and not text.
- [ ] `part_number` and `output_count` were filled in by the database, and
      `match_status` is `matched`.
- [ ] **Submit the real Form from a phone.** The row lands, and
      `production_date` is the date that was picked.
- [ ] **Submit a night-shift entry after 20:00.** `production_date` is still the
      date that was picked and has not slipped a day back. This is the only way to
      catch the time zone problem, so actually do it.
- [ ] Stop the gateway service, submit a response, and confirm the flow run fails
      but the item is still safe in SharePoint. Restart the gateway, re-run the
      failed run from the run history, and confirm the row arrives.
- [ ] `select count(*) from "Daily_Output";` is **unchanged** by all of the above.

That last one matters. Form responses are deliberately kept out of `Daily_Output`,
because that table feeds `JobOrder.produced_qty` and **automatically closes a job
order** once produced reaches the ordered quantity. A phone form has no
autocomplete to check a JO number against, so one typo would close a live job
order. Nothing in this setup writes there.

---

## 9. Living with it

### Responses that arrived before the job order existed

Operators are often quicker than the office, so a response can land before anyone
has created its job order. It sits at `match_status = 'no_jo'` and will stay there.

After creating job orders, run:

```sql
select rematch_form_daily_output();
```

It re-checks everything still unresolved against current master data and returns
how many rows changed. It is safe to run at any time, as often as you like.

### What to look at now and then

```sql
-- anything that did not resolve cleanly
select match_status, count(*)
  from form_daily_output
 group by match_status;

-- the actual problem rows
select sp_item_id, production_date, operator, jo_number, process,
       part_name, match_status
  from form_daily_output
 where match_status <> 'matched'
 order by production_date desc;
```

A lot of `ambiguous` means the Form is not asking for something it needs — go back
to section 1. A lot of `conflict` means people are typing process or part names
that do not match the master data, which is usually a training or a
drop-down-list fix rather than a database one.

### Reading the data in Power BI

The table is `form_daily_output` on the same server, so connect exactly as
`docs/powerbi-inspection-guide.md` describes and pick that table. Filter on
`match_status = 'matched'` unless you specifically want to see the problem rows.

---

## 10. When something breaks

| Symptom | Almost always |
|---|---|
| Connection test fails with an SSL / certificate error | The SSL mode on the connection. Section 5 |
| Gateway shows **Offline** | The Windows service on the server is stopped, or the server rebooted and it did not come back |
| Flow fails on **Insert row** with a duplicate key error | That response is already in the table. Harmless — the database refused to duplicate it |
| Flow fails with `float('')` or a conversion error | An empty number answer. Add the `if(empty(...), null, ...)` guard from section 6 |
| Rows arrive but part number is empty | `match_status` will say why — usually `ambiguous` because the Form did not collect the process |
| Everything says `no_jo` | The JO numbers on the Form do not look like the ones in `JobOrder`. Check a real one: `select "JO_Number" from "JobOrder" limit 5;` |
| Dates are one day early | The time zone conversion warning in section 6. Do not convert `production_date` |
| Nothing arrives at all, no failed runs | The **existing** Form→SharePoint flow is off, so no items are being created for your new flow to react to. Check that flow's run history |

### Where things live

| What | Where |
|---|---|
| The table, trigger and matching rules | `sql/2026-08-17_form_daily_output.sql` |
| Why it is built this way | the header comment of that same file |
| The shop-floor equivalent screen | `screen_page/production_planning/daily_output.html` |
| The flows | make.powerautomate.com → **My flows** |
| The gateway | the on-premises data gateway app on `192.168.0.5` |
