# Fanuc part count → Supabase

Plan. Nothing built yet.

## Context

Daily production output is typed in by hand today. `screen_page/production_planning/daily_output.html`
asks an operator for **Machine Counter Start** and **Machine Counter End**, read off the machine's
own display, plus rejects, and computes:

```
output_count = counter_end − counter_start − reject_qty
```

We want the machine to report that itself, every day, with no operator entry.

The counter already exists on the controller. Fanuc exposes it as macro variable **`#3901`**
(parts count) and parameter **`6711`** (parts machined) / `6712` (total) / `6713` (required),
readable over Ethernet through **FOCAS2**. Machines are on the LAN, the FOCAS library is
available, and a third-party system already reads availability off these controllers — which is
useful proof that FOCAS-over-Ethernet works here.

**Decisions already taken:** our own poller, independent of the third-party system; rejects
derived from IPQC data; one cycle = one part.

---

## What this touches — read this first

`Daily_Output` is not a leaf table. From `sql/2026-07-28_joborder_production_progress.sql`:

```
machine counter → Daily_Output.output_count → JobOrder.produced_qty → production_completed_at
                                                                      (set when produced_qty >= Quantity)
```

A number written automatically into `output_count` **flags job orders as production-complete**.
An over-count closes a job that still has parts to run. That is the risk that governs the whole
design, and it is why the plan below writes the machine figure into its **own column** and leaves
`output_count` alone until a human or a rule promotes it.

---

## Three things that make "fully automatic" harder than it looks

### 1. The controller does not know the job order

`Daily_Output` rows are keyed by `(production_date, shift, jo_number, process, machine_no)`.
FOCAS gives us `machine + count + time`. It has no idea what JO is running.

**Approach:** read the running program alongside the counter (`cnc_exeprgname` / `cnc_rdprgnum`)
and map program → part → JO. That needs a mapping table; `cycle_time` already pairs
`machine / part_no / part_name / process`, so it is a reasonable base but does not carry the
O-number.

**Rule: never guess the JO.** A sample whose program maps to nothing gets written with
`jo_number = null` and parked for review. A wrong attribution silently credits parts to the wrong
job and closes it early — far worse than an unattributed row somebody assigns in ten seconds.

### 2. Rejects cannot honestly come from IPQC — stated once, then built as asked

You chose to derive rejects from IPQC. I want the limitation on record, because it decides how
much weight the derived number can carry:

- **IPQC is sampling inspection, not 100% inspection.** It measures a few points per round. The
  number of parts scrapped in a shift is not a fact IPQC holds.
- `affected_qty` is the only reject-ish quantity, and it is **per-inspection, repeated on every row
  of a submission** — `sql/2026-08-07_ipqc_affected_qty_per_inspection.sql` says explicitly:
  *"NEVER SUM IT."* It must be `max()` per submission, then summed across submissions.
- It is **free text**, and the common honest answer is `ALL`, for which `affected_qty_num` is null
  — a quantity nobody counted.
- As of 2026-08-07 **all 75,419 rows had it null.** It is only now being keyed in, through the
  reject report screen. For most shifts this derivation will return nothing.

**So it is built, but it is built as an estimate that cannot close a job:** a separate
`reject_qty_derived` column plus a `reject_source` of `'ipqc'|'manual'|'none'` and a coverage
count. It never feeds `output_count` on its own. When the derived reject is null — which will be
most shifts at first — the machine count stands as **gross**, and it is labelled gross.

### 3. Counters reset, and machines go offline

`#3901` is resettable by the operator and by the program (`#3901=0` at program start is a common
pattern). Sampling a running total means:

- **A decrease is a reset, not negative production.** On `sample < previous`, close the previous
  segment and start a new one; never subtract across the reset.
- **A gap is not zero.** Machine off, network down, or the poller not running must record *no
  data*, not a count of nought. A shift with a gap is marked incomplete rather than reported low.
- **Sanity-check the rate.** `cycle_time.cycle_time_sec` gives the expected seconds per part per
  machine/part/process. A jump implying a rate far faster than the cycle time is a counter reset,
  a program change, or a bad read — flag it, do not ingest it silently.

---

## Architecture

```
Fanuc controller  ──FOCAS2/Ethernet──▶  collector  ──▶  machine_count_sample   (raw, append-only)
   #3901 + program                        (5 min)              │
                                                               ▼
                                                   machine_shift_output  (derived per shift)
                                                               │
                                                    review / promote (rule or human)
                                                               ▼
                                                        Daily_Output
```

Raw samples are kept forever and never edited. Everything else is derived from them and can be
recomputed — so a mapping fixed next month repairs last month's numbers without re-reading any
machine.

### The FOCAS bitness problem

`Fwlib32.dll` is historically a **32-bit** C library. A 64-bit Node process cannot load it.

1. **Preferred:** if your FOCAS2 SDK includes the **x64** library, call it from Node with `koffi`
   (modern, works on Node 22, no build step). Keeps the system in one language.
2. **Fallback:** if only the 32-bit DLL exists, a small **helper executable** (C# or C++) owns the
   DLL and writes samples itself. More robust than fighting the FFI, at the cost of a second
   language in the repo.

Check which you have before writing any code — it decides the collector's shape.

### Where it runs

Same as the SharePoint sync: a scheduled task, **not** inside `server.js`. Config and logs outside
the repo root, because `server.js:27` is `app.use(express.static(__dirname))` and serves the whole
repo with no auth. See `.claude/plans/cozy-juggling-shamir.md` for the Task Scheduler specifics —
absolute node path, "Start in", no `pause`, distinct exit codes, logs in `C:\ProgramData`.

---

## Schema — `sql/2026-08-13_machine_part_count.sql`

House style: essay header, `begin;`/`commit;`, idempotent, `comment on` everywhere,
`notify pgrst, 'reload schema';`, trailing NOTES with verify queries.

**`machine_count_sample`** — raw, append-only, the source of truth.
`id`, `machine_no`, `sampled_at timestamptz not null`, `part_count bigint`, `program_no text`,
`program_name text`, `cnc_mode text`, `run_state text`, `raw jsonb`.
Index `(machine_no, sampled_at desc)`. Unique on `(machine_no, sampled_at)` so a re-run cannot
duplicate. No update or delete policy — samples are evidence.

**`machine_program_map`** — program → part/process. `machine_no`, `program_no`, `part_no`,
`process`, `parts_per_cycle int not null default 1`, `updated_by`. Unique
`(machine_no, program_no)`. `parts_per_cycle` is 1 for you today; it exists so multi-cavity work
later is a data change, not a migration.

**`machine_shift_output`** — one row per `(production_date, shift, machine_no, jo_number, process)`.
`count_gross bigint`, `count_start`, `count_end`, `reset_events int`, `sample_gaps int`,
`first_sample_at`, `last_sample_at`, `reject_qty_derived`, `reject_source text`,
`reject_coverage int`, `status text` (`'complete' | 'gap' | 'unattributed' | 'suspect'`),
`promoted_to_daily_output_id bigint`. Unique on the five key columns.

**RLS:** `select` to anon on all three; writes from the collector only. Same reasoning as the
SharePoint plan — shop-floor screens must not be able to edit machine evidence. Note the same
caveat: the anon key here is signed with Supabase's published default self-hosting secret, so this
is the right shape but not a real boundary until `JWT_SECRET` is rotated.

**`Daily_Output`** gains `machine_count_gross bigint` and `count_source text`
(`'manual' | 'machine' | 'machine+manual'`). **`output_count` keeps its current meaning.** Existing
rows and existing reports are untouched.

---

## Rollout — one machine first

The connection-contention risk is the reason. Your third-party system is already holding FOCAS
connections to these controllers, and per-controller concurrent connections are limited (the exact
number is model-dependent; I could not confirm it for your machines from vendor documentation).
The failure mode is *the existing availability monitoring starts dropping out*, and someone else
notices before you do.

1. **One machine, read-only, 5-minute polling, for a week.** Watch the third-party system for
   dropouts over that whole week. If it degrades, back off the interval before anything else.
2. **Prove the counter means what we think.** Run a known quantity, compare the counter delta to
   the physical parts. Do this per machine model, not once.
3. **Shadow mode.** Derive `machine_shift_output` and compare against what operators typed for the
   same shift. Do not write to `Daily_Output`. Review the differences — this is where counter
   resets, job attribution errors, and the reject gap all show themselves against real data.
4. **Promote** only after shadow mode is boring. Then extend machine by machine.

---

## Verification

1. **Connect** — `--check-machine <ip>` prints controller id, series, and `#3901`. Proves FOCAS.
2. **Read** — counter matches what the machine's own screen shows, right now, by eye.
3. **Sample** — samples land at the expected interval; `raw` holds the full response.
4. **Reset** — reset the counter on the machine. Expect a new segment, `reset_events` = 1, and
   **no negative count**.
5. **Gap** — pull the network cable for 20 minutes. Expect missing samples, `status = 'gap'`, and
   no zero-filled rows.
6. **Attribution** — change the program. Expect the new `program_no` on samples and, once mapped,
   the right JO. Expect `status = 'unattributed'` for an unmapped program, never a guess.
7. **Shadow** — one full week of machine vs operator figures per shift. Quantify the difference
   before trusting anything.
8. **Rate check** — confirm a suspicious jump is flagged `'suspect'` against `cycle_time_sec`.
9. **No collateral damage** — `JobOrder.produced_qty` and `production_completed_at` must be
   **unchanged** through all of the above. Verify with a before/after query, not by eye.
10. **Third-party system healthy** — check its uptime across the whole pilot week.

---

## Open items

- **32-bit vs 64-bit FOCAS library** — decides the collector's language. Check first.
- **Controller series per machine** — still unknown; affects which read calls work.
- **Program → part mapping** — needs to be populated, and needs an owner. Where does the O-number
  live today?
- **Night shift crossing midnight** — `sql/2026-07-28_shift_output.sql` attributes a 19:00–05:00
  shift to its **start** date. Sample bucketing must follow that, or every night shift is split
  across two dates.
- **What happens to the operator form** once machine counts are trusted? "Fully automatic" and the
  reject gap are in tension: someone still has to say what was scrapped.
