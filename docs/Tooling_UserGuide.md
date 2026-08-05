# Tooling — User Guide

A guide to the three **Tooling** screens in the Famax QC System: the Masterlist, Transactions and
Assignment.

> The pages are at `screen_page/tooling/`:
> `tooling_masterlist.html`, `tooling_transaction.html`, `tooling_assignment.html`.
>
> **One-time setup.** An admin must run these SQL files in `sql/`, in this order, or all three pages
> load with an error:
> 1. `2026-08-05_tooling_access.sql`
> 2. `2026-08-06_tooling_usage_unique.sql` and `2026-08-06_tooling_codes_and_intake.sql`
>    (either order)
>
> If a page says *"Could not load"* and mentions a missing relation, column or function, that is
> the missing migration talking.

---

## 1. The idea behind all three screens

Three things you need to hold on to. Everything else follows from them.

### A tool has two levels

| Level | What it is | Example |
|-------|------------|---------|
| **Tool type** | The tool itself, by shape and size | `FTL-0001` — TNMG 0.2 |
| **Stock item** | The actual thing you buy, by brand | `FTI-00001` — TNMG160402-MA, MDBT |

One tool type can have several stock items — the same insert from MDBT, Kennametal and Sumitomo are
three items under one type. You **issue a stock item**, because that is the box on the shelf. You
**assign a tool type** to a part, because the part does not care whose brand you fit.

### A tool is in one of three places

| Number | Meaning |
|--------|---------|
| **On the shelf** | In the store, usable, ready to issue |
| **Out on the floor** | Issued to production, not yet returned |
| **Worn out** | Came back worn and was written off |

They always reconcile:

```
opening + receipts − sells  =  on the shelf + on the floor + worn out
```

### Stock is never typed in — it is counted from movements

There is no "quantity" box you can edit on an item. Every number on every screen is added up from
the movement history, so it can never disagree with it. To change stock you record a movement, and
every movement carries a date, a reason and a name.

---

## 2. Tooling Masterlist

**What it is for:** looking up a tool, seeing what is on the shelf, and keeping the catalogue tidy.

Open it from the home dashboard → **Tooling Masterlist** tile, or the sidebar → *Tooling* →
**Tooling Masterlist**.

_[Screenshot to capture: full masterlist with rail]_

### 2.1 The side rail (left)

| Section | What it does |
|---------|--------------|
| **FAMAX / Tooling Masterlist** | Brand and page name |
| **Signed in as** | Your user, and a badge with your access level |
| Badge reads **Read only** | You can look but not change anything — see §5 |
| **Session active** | A session is loaded |
| **Categories** | Filters the list to one category. The number is how many tool types are in it |
| **All tools** | Clears the category filter |
| **+ Tool type** | Creates a new tool type (§2.5). Hidden if you cannot write |
| **Transactions** | Jumps to the Tooling Transaction screen |
| **Back to Dashboard** | Returns to the main menu |

Clicking the category you are already on turns it off, which is the same as **All tools**.

### 2.2 Toolbar and filters

| Control | What it does |
|---------|--------------|
| **Refresh** | Re-reads everything from the database |
| **Search** | Matches tool code, tool name, category, item code, manufacturer code, brand, supplier and location — so searching `MDBT` or `INSERT LOCKER` works as well as `TNMG` |
| **Show** | Narrows to a condition (below) |
| **Sort** | Tool code, Name, Most stock, Least stock |

**Show** options:

| Option | Shows |
|--------|-------|
| All tools | Everything |
| In stock | Anything with 1 or more on the shelf |
| Out of stock | Anything at 0 |
| At / below reorder | Items that have hit the reorder point you set |
| Out on the floor | Tools with something issued and not yet returned |
| Needs review | Tool types flagged for checking |

### 2.3 The summary strip

Counts for **what is on screen**, not the whole table — filter to `TNMG` and every figure describes
those tools only. **Needs review** is a link: click the number to jump straight to that queue.

### 2.4 The list

One row per **tool type**. Click anywhere on a row to open it.

| Column | Meaning |
|--------|---------|
| **Tool code** | `FTL-nnnn`, assigned automatically |
| **Name** | With a **NEEDS REVIEW** pill if flagged |
| **Category** | Colour-tinted by category |
| **Size** | Nominal size, if recorded |
| **Items** | How many brands / part numbers exist for this tool |
| **On shelf** | Grey = zero · amber bold = at or below reorder |
| **Floor / Scrapped** | Deliberately greyed — only **On shelf** answers "can I issue this?" |
| **Edit** | Opens the tool type dialog |

Opening a row reveals its **stock items**, preferred brand first:

| Column | Meaning |
|--------|---------|
| **Item code** | `FTI-nnnnn`, assigned automatically |
| **PREF** pill | The brand normally bought for this tool |
| **INACTIVE** pill | No longer bought — kept for history |
| **Manufacturer code / Brand / Supplier** | Who makes and sells it |
| **Location** | Where it lives in the store |
| **Reorder** | Alert level. Blank means no alert |
| **On shelf** | A **▼** appears when at or below reorder |
| **+ Item** | Adds another brand under this tool (§2.6) |

### 2.5 Dialog — Tool type

Opened by **+ Tool type** (new) or **Edit** on a row.

| Field | Notes |
|-------|-------|
| **Tool code** | Greyed out. Reads *"Assigned on save"* — the database issues the next `FTL-` number |
| **Category** * | Required |
| **Tool name** * | Required. As written on the box or tool list |
| **Nominal size** | Optional |
| **Review** | Tick to flag the entry for someone to check |
| **Remarks** | Free text |

Buttons: **Cancel** (or `Esc`, or the **×**) discards. **Add tool type** / **Save changes** saves.

> There is no Delete. Removing a tool type would take its stock items and their movement history
> with it. Mark the items **Inactive** instead.

### 2.6 Dialog — Stock item

Opened by **+ Item** or **Edit** on an item row.

| Field | Notes |
|-------|-------|
| **Item code** | Greyed out — the database issues the next `FTI-` number |
| **Manufacturer code** | The maker's own code, e.g. `TNMG160402-MA` |
| **Brand / Supplier / Location** | Free text, but previous entries are offered as you type so spellings stay consistent |
| **Reorder point** | Blank means *no alert*. That is **not** the same as `0` |
| **Preferred** | The brand normally bought for this tool |
| **Active** | Untick when you stop buying it |
| **Remarks** | Free text |

**Opening stock — on a new item only:**

| Field | Notes |
|-------|-------|
| **Quantity on the shelf** | Optional. Leave blank to register the item now and count it later |
| **How it got here** | *Opening count* (already on the shelf) or *Receipt* (bought against a PO) |
| **PO number** | Appears only for a receipt |
| **Recorded by** * | Required once you enter a quantity |
| **PIN** * | That person's EmployeeTable PIN. Checked, never stored |

The item and its opening count are saved **together** — either both or neither. An item can never
exist holding stock that was not recorded.

_[Screenshot to capture: new stock item dialog with Opening stock section]_

On an **existing** item there is no quantity box. Stock changes are movements — use the Transaction
screen.

---

## 3. Tooling Transaction

**What it is for:** every movement in and out of the store.

Open from the dashboard → **Tooling Transaction**, the sidebar, or the **Transactions** button on
the masterlist rail.

_[Screenshot to capture: transaction screen with an item selected]_

### 3.1 Section 1 · Which tool

Search by item code, tool code, tool name, manufacturer code, brand or location, then click a row.
Without a search the first 60 items are listed; the note underneath says so.

### 3.2 Section 2 · The item

Four boxes across the top: **On the shelf**, **Out on the floor**, **Worn out**, and **Location**
(with the reorder point if one is set). The shelf box turns amber when at or below reorder.

**Movement type** — pick one, and the form changes to suit:

| Button | Use it when | Effect |
|--------|-------------|--------|
| **Receive** | Stock arrives against a PO | Shelf ↑ |
| **Issue to production** | A tool goes out to a machine | Shelf ↓, Floor ↑ |
| **Issue as spare** | A tool goes out as a spare | Shelf ↓, Floor ↑ |
| **Return from production** | A tool comes back — see below | Shelf ↑ / Floor ↓ |
| **Sell** | Stock is sold on | Shelf ↓ |
| **Stock count** | The shelf does not match the system | Shelf corrected |

**Returning a tool is two answers, not one.** The form gives you two boxes:

| Box | Meaning |
|-----|---------|
| **Reusable — goes back on the shelf** | Still has life in it |
| **Worn out — cannot be reused** | Written off. Does **not** go back on the shelf |

Fill in either, or both. Ten tools going out and coming back as 3 good and 2 worn is one return with
`3` and `2` in the boxes — and 5 still on the floor. Both are recorded; only the reusable ones
return to stock.

If a tool-life standard has been set for this tool (see §4), a blue note shows it here — that is the
figure the reuse-or-scrap judgement is made against. If none is set, the note says so.

**Stock count** asks for what is *physically on the shelf*, not a difference. The correction is
worked out for you. Counting exactly what the system already says reports that there is nothing to
record.

**Part / Process / Machine** appear only for issues and returns. A PO receipt has no part, so it
does not ask for one. Part numbers are offered from the main Parts list so tooling spells them the
same way as the rest of the system.

**The grey line above the buttons** always tells you what will happen before you commit:

> Shelf 95 → 85, floor 0 → 10.

It turns amber and explains itself if you issue more than is on the shelf, or return more than is
out. Both still save — a miscounted shelf is more likely than a refused movement being correct —
but the warning tells you a movement is missing somewhere.

| Field | Notes |
|-------|-------|
| **Remarks** | Optional |
| **Recorded by** * | Name from EmployeeTable |
| **PIN** * | That person's PIN. Checked, never stored |
| **Record movement** | Saves. A return with both boxes filled saves as two rows at once |

### 3.3 Section 3 · Movements

Newest first.

| Column | Meaning |
|--------|---------|
| **When** | Date and time, Malaysian time |
| **Movement** | Green = came in · red = went out · grey = worn out |
| **Qty** | Signed: `+` in, `−` out |
| **Shelf after** | Running balance. A *worn out* row leaves it unchanged — those tools left the shelf when they were issued |
| **Part / Process**, **Machine / PO**, **By**, **Remarks** | As recorded |

---

## 4. Tooling Assignment

**What it is for:** recording which tools a part needs, at which process, and how long a tool should
last there.

_[Screenshot to capture: assignment screen, By part, with process blocks]_

### 4.1 By part / By tool

Two buttons at the top switch which way round you ask the question. Same information either way.

- **By part** — *"what does this part need at HT1?"* Use when setting up a job.
- **By tool** — *"where is this tool used?"* Use before dropping or replacing a tool.

### 4.2 By part

**1 · Which part** — search and click. Columns are Part number, Description and **Tools** (how many
assignments it has).

A **NOT ON MASTER** pill means that part number is not on the main Parts list — usually a spelling
difference worth reconciling. It is flagged, never changed for you.

**Add a part from the Parts master** — pick or type a part number and press **Add part** to bring it
into the tooling list. Choosing from the offered list keeps the spelling consistent.

**2 · The part** — tools grouped into **one block per process**, in the order the shop runs them.
A block headed **"No process named"** sorts last and means *this tool is used on the part whatever
the operation*.

| Column | Meaning |
|--------|---------|
| **Tool** | Tool code and name, with an **INACTIVE** pill if deactivated |
| **Category** | The tool's category |
| **Tool life (pcs)** | Pieces one tool is expected to give here. Edit in place |
| **Setup dia (mm)** | Standard setup diameter. Edit in place |
| **Remarks** | Edit in place |
| **Deactivate / Reactivate** | Keeps the row and its history, marks it not in use |
| **Remove** | Deletes the assignment. Asks first |

Inline edits save when you click away. The box greys while saving and turns red if it fails. Tool
life must be more than 0, or blank — blank means *no standard set*, which is different from zero.

**Add a tool to this part** — pick the tool, pick the process (or *No process named*), optionally
set a tool life, press **Add**. If that exact combination already exists you are told which row it
is, so you can edit it instead of creating a duplicate.

### 4.3 By tool

**1 · Which tool** — search and click. **Used on** counts its assignments.

**2 · The tool** — every part and process it is used on, with the same editable columns and the same
Deactivate / Remove buttons. Parts not on the main Parts list carry the same **NOT ON MASTER** pill.

If a tool has no assignments the page says so, and tells you how many others are in the same state —
the original import brought the tool catalogue, not the routings.

### 4.4 What tool life is, and is not

It is a **standard**: the pieces one tool is expected to give on this part at this process. It is
what the Transaction screen shows when somebody decides whether a returned tool still has life in
it.

It is **not** a running total. A stock item is a quantity of identical tools, not individually
numbered ones, so nothing counts down against it.

---

## 5. Who can do what

Access comes from your login. Everyone who can open a page can read it; writing is separate.

| Access level | Masterlist | Transaction | Assignment |
|--------------|-----------|-------------|------------|
| **ALL** | Edit | Record | Edit |
| **QUALITY** | Edit | Record | Edit |
| **MANAGEMENT** | Edit | Record | Edit |
| **PRODUCTION** | — | **Record** | — |

Production gets the Transaction screen because issuing and returning tools is their work.

When you cannot write, an amber bar says so and the buttons are simply absent rather than present
and failing.

Recording a movement or an opening count additionally needs a **name and PIN from EmployeeTable** —
separate from your login. That is what puts a person's name against a stock figure. If the dropdown
says *"No PIN holders found"*, someone needs a PIN set in EmployeeTable.

---

## 6. Common questions

**Why can I not type a tool or item code?**
They are running numbers issued by the database, so two people adding tools at the same time cannot
collide or leave a gap.

**I added an item but stock shows 0.**
The opening quantity was left blank. Record a *Stock count* on the Transaction screen.

**"Out on the floor" is negative.**
More has been returned than was ever issued, so an issue was never entered. Find it and record it.

**A tool is worn out but the shelf figure did not drop when I recorded it.**
Correct. It left the shelf when it was issued. The scrap return reduces *Out on the floor* and
raises *Worn out*.

**I need to correct a movement.**
Movements are a permanent record and are not edited. Record the correcting movement — usually a
*Stock count* — so both the error and the correction stay visible.

**A part number looks wrong / is flagged NOT ON MASTER.**
Add the correct spelling from the Parts master and move the assignments over. Nothing is renamed
automatically, because only a person can tell a typo from a part the master is missing.
