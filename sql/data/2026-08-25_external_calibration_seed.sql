-- 2026-08-25  MASTERLIST EXTERNAL CALIBRATION 2025 - 2026.xlsx, loaded.
--
-- All 18 rows of the EXTERNAL MASTERLIST sheet, transcribed as they read. Nothing is corrected on
-- the way in - not the brand column on item 2 (SN-500 is a model, not a maker), not the two
-- spellings of QA/QC and QA/QC LAB, not "PITCH DIAMETR" on items 3 and 4. A masterlist that
-- silently disagrees with the signed record it replaced is worse than one that repeats its typos,
-- and every one of these is a two-second edit on the page once somebody decides what it should say.
--
-- Two rows are worth reading twice before running this:
--
--   Item 11, WEIGHCOM counting scale A08326347. Calibrated 25 JUL 2025, due 24 JUL 2026 - already
--   overdue. It loads overdue. That is not a seeding bug to paper over; it is the finding, and it
--   is why the alert exists.
--
--   Item 18, CHENXI microscope lamp CX-HV4800. The sheet reads NA in both date columns, so it
--   loads with calibration_required = false and NO calibration event at all. A lamp with a due
--   date would be a lie, and a lamp with a null due date in a list of due dates reads as an
--   oversight. NOT_REQUIRED says which it is.
--
-- Idempotent. Equipment is matched on (equipment_code, serial_no) and events on
-- (equipment_id, cal_date), so re-running updates in place rather than duplicating.
--
-- Run AFTER sql/2026-08-25_external_calibration.sql:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/data/2026-08-25_external_calibration_seed.sql

begin;

-- The sheet as one literal. Kept in one place so the equipment insert and the event insert cannot
-- transcribe the same certificate two different ways.
create temporary table _seed (
    sort_order      int,
    equipment_code  text,
    type_code       text,
    description     text,
    serial_no       text,
    brand           text,
    location        text,
    cal_date        date,
    due_date        date,
    criteria        text,
    condition       text,
    interval_months int
) on commit drop;

insert into _seed values
 ( 10, 'PP',    'PP',  'PROFILE MEASURING',                             '760146',        'MITUTOYO',        'IPQC WORKPLACE',  '2025-11-28', '2026-11-28', E'± 0.005mm',                                                                                  'GOOD',        12),
 ( 20, 'PG',    'PG',  'DIAL PUSH PULLGAUGE',                           '2809116082',    'SN-500',          'QA/QC LAB',       '2025-12-03', '2026-12-03', E'T (P) : ±0.05 kgf\nC (P) : ±0.05 kgf',                                                  'GOOD',        12),
 ( 30, 'TRG',   'TRG', 'M23 X 1.25 6g',                                 'AJ724 / AJ736', 'RAINBOW',         'QA/QC',           '2025-12-04', '2026-12-04', E'MINOR DIAMETER\nGO: 21.6280, NOGO: 21.7430\nPITCH DIAMETR\nGO: 22.1730, NOGO: 22.0020',           'OUT OF SPEC', 12),
 ( 40, 'TPG',   'TPG', 'M4 X 0.7 6H',                                   'N/A',           'N/A',             'QA/QC',           '2025-12-05', '2026-12-05', E'MAJOR DIAMETER\nGO: 3.997, NOGO: 3.817\nPITCH DIAMETR\nGO: 3.539, NOGO: 3.673',                   'GOOD',        12),
 ( 50, 'FS',    'FS',  'DIGITAL FLOOR SCALE',                           '12/24/1888-04', 'MAGODA (E2G)',    'STORE & PACKING', '2025-12-15', '2026-12-14', '0.5kg',                                                                                           'GOOD',        12),
 ( 60, 'CMM',   'CMM', 'COORDINATE MEASURING MACHINE',                  '71426230',      'MITUTOYO',        'QA/QC LAB',       '2025-12-19', '2026-12-19', E'± (1.9 + 4L/1000)µm',                                                                   'GOOD',        12),
 ( 70, 'VMM',   'VMM', 'VIDEO MEASURING MACHINE',                       'Q012010015',    'JATEN',           'MAZAK ROOM',      '2026-02-06', '2027-02-06', E'± 0.005mm',                                                                                  'GOOD',        12),
 ( 80, 'VMM02', 'VMM', 'VIDEO MEASURING MACHINE',                       '2529115',       'JINUOSH',         'QA/QC LAB',       '2026-03-29', '2027-03-29', E'±0.005mm',                                                                                   'GOOD',        12),
 ( 90, 'CS',    'CS',  E'DIGITAL COUNTING SCALE\n(6000g x 0.2g)',       '23101132',      'HALSTEN (BC-6-E)','STORE & PACKING', '2026-07-23', '2027-07-22', '0.2g',                                                                                            'GOOD',        12),
 (100, 'WM',    'WM',  E'DIGITAL COUNTING PLATFORM SCALE\n(150kg X 0.01kg)','AL0947',    'MME (CS SERIES)', 'STORE & PACKING', '2026-07-23', '2027-07-22', '0.01kg',                                                                                          'GOOD',        12),
 (110, 'CS',    'CS',  E'DIGITAL COUNTING SCALE\n(6000g X 0.2g)',       'A08326347',     'WEIGHCOM',        'STORE & PACKING', '2025-07-25', '2026-07-24', '0.2g',                                                                                            'GOOD',        12),
 (120, 'BG',    'BG',  'BLOCK GAUGE (10MM)',                            '09033',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.12µm\nVL : ± 0.10µm',                                               'GOOD',        60),
 (130, 'BG',    'BG',  'BLOCK GAUGE (25MM)',                            '06014',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.14µm\nVL : ± 0.10µm',                                               'GOOD',        60),
 (140, 'BG',    'BG',  'BLOCK GAUGE (50MM)',                            '05015',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.20µm\nVL : ± 0.10µm',                                               'GOOD',        60),
 (150, 'BG',    'BG',  'BLOCK GAUGE (75MM)',                            '05156',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.25µm\nVL : ± 0.12µm',                                               'GOOD',        60),
 (160, 'BG',    'BG',  'BLOCK GAUGE (100MM)',                           '09003',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.30µm\nVL : ± 0.12µm',                                               'GOOD',        60),
 (170, 'BG',    'BG',  'BLOCK GAUGE (150MM)',                           '07289',         'MICRON',          'QA/QC LAB',       '2021-12-07', '2026-12-07', E'DCL : ± 0.40µm\nVL : ± 0.14µm',                                               'GOOD',        60),
 -- The lamp. NULL dates, not NA text: see the header.
 (180, 'DLM',   'DLM', 'DIMMABLE LED MICROSCOPE LAMP',                  'CX-HV4800',     'CHENXI',          'QA/QC LAB',        null,         null,        '20-160MM',                                                                                        'GOOD',        12);

-- ---------------------------------------------------------------------
-- Equipment
-- ---------------------------------------------------------------------
--
-- Matched on (equipment_code, serial_no) - the same pair the partial unique index enforces - so
-- the two CS scales stay two rows and re-running this file edits rather than duplicates.
-- accepted_criteria is the CURRENT criteria; the same text is copied onto the certificate below,
-- where it becomes the historical snapshot.

insert into ext_cal_equipment (
    equipment_code, type_code, description, serial_no, brand, location,
    accepted_criteria, condition, cal_interval_months, calibration_required,
    status, sort_order, created_by, updated_by)
select s.equipment_code, s.type_code, s.description, s.serial_no, s.brand, s.location,
       s.criteria, s.condition, s.interval_months, s.cal_date is not null,
       'ACTIVE', s.sort_order, 'MIGRATION 2026-08-25', 'MIGRATION 2026-08-25'
  from _seed s
on conflict (equipment_code, serial_no)
   where serial_no is not null and serial_no <> '' and upper(serial_no) <> 'N/A'
do update set
    type_code            = excluded.type_code,
    description          = excluded.description,
    brand                = excluded.brand,
    location             = excluded.location,
    accepted_criteria    = excluded.accepted_criteria,
    condition            = excluded.condition,
    cal_interval_months  = excluded.cal_interval_months,
    calibration_required = excluded.calibration_required,
    sort_order           = excluded.sort_order,
    updated_at           = now(),
    updated_by           = 'MIGRATION 2026-08-25';

-- Item 4 carries serial N/A, so the partial index does not cover it and ON CONFLICT could not
-- either. Inserted separately, guarded by NOT EXISTS on the description instead.
insert into ext_cal_equipment (
    equipment_code, type_code, description, serial_no, brand, location,
    accepted_criteria, condition, cal_interval_months, calibration_required,
    status, sort_order, created_by, updated_by)
select s.equipment_code, s.type_code, s.description, s.serial_no, s.brand, s.location,
       s.criteria, s.condition, s.interval_months, s.cal_date is not null,
       'ACTIVE', s.sort_order, 'MIGRATION 2026-08-25', 'MIGRATION 2026-08-25'
  from _seed s
 where upper(coalesce(s.serial_no, '')) in ('', 'N/A')
   and not exists (
       select 1 from ext_cal_equipment e
        where e.equipment_code = s.equipment_code
          and e.description    = s.description);

-- ---------------------------------------------------------------------
-- The certificate each row is currently carrying
-- ---------------------------------------------------------------------
--
-- One event per instrument, dated as the sheet dates it. lab is null on purpose: the spreadsheet
-- never recorded who calibrated any of this, and inventing "External Lab" would put a fact in the
-- record that nobody stated. It is a required-looking field on the entry form from here on, so the
-- gap closes on the next certificate rather than being back-filled with a guess.
--
-- result likewise. The sheet has a CONDITION column, not a PASS/FAIL - so condition carries what
-- was written and result stays null, except where the condition itself says the instrument failed.

insert into ext_cal_event (
    equipment_id, cal_date, due_date, cert_no, lab, result, condition, criteria,
    remarks, recorded_by)
select e.id, s.cal_date, s.due_date, null, null,
       case when s.condition = 'OUT OF SPEC' then 'FAIL' end,
       s.condition, s.criteria,
       'Loaded from MASTERLIST EXTERNAL CALIBRATION 2025 - 2026.xlsx',
       'MIGRATION 2026-08-25'
  from _seed s
  join ext_cal_equipment e
    on e.equipment_code = s.equipment_code
   and e.description    = s.description
   and coalesce(e.serial_no, '') = coalesce(s.serial_no, '')
 where s.cal_date is not null
on conflict (equipment_id, cal_date) do update set
    due_date  = excluded.due_date,
    result    = excluded.result,
    condition = excluded.condition,
    criteria  = excluded.criteria;

commit;

-- =====================================================================
--  Verify
-- =====================================================================
--   select count(*) from ext_cal_equipment;                     -- 18
--   select count(*) from ext_cal_event;                         -- 17  (the lamp has none)
--   select cal_status, count(*) from v_ext_cal_masterlist group by 1 order by 2 desc;
--   -- and the row this whole exercise is about:
--   select equipment_code, serial_no, next_due_date, days_to_due, cal_status
--     from v_ext_cal_masterlist where cal_status = 'OVERDUE';   -- CS / A08326347
