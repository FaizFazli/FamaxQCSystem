-- 2026-08-25  MASTERLIST EXTERNAL CALIBRATION 2024 - 2025.xlsx, loaded as history.
--
-- The previous revision of REC-QAS010-05: 19 instruments over two pages, signed by JESS LIM and
-- dated 21/12/2024. Nothing in it is current - every instrument on it has either been recalibrated
-- since or has left the list. It is loaded because a masterlist whose history begins on the day it
-- was computerised cannot answer the question calibration records exist to answer: was this
-- instrument in tolerance when it measured that part.
--
-- This file adds PRIOR CERTIFICATES to instruments that already exist, and registers the three
-- that were retired between the two revisions. It changes no current condition, no current due
-- date, and no current criteria. Re-running it is a no-op.
--
-- ---------------------------------------------------------------------
-- WHAT THE TWO SHEETS DISAGREE ABOUT, AND WHAT WAS DONE
-- ---------------------------------------------------------------------
--
-- A. THE SIX BLOCK GAUGES ARE THE SAME CERTIFICATE, TWICE.
--    Both sheets carry 7-Dec-21 -> 7-Dec-26 for all six MICRON gauges. That is one certificate
--    written on two forms, not two calibrations, so it loads once. The unique index on
--    (equipment_id, cal_date) makes that automatic rather than a thing to remember.
--
--    Their serials are written with and without a leading zero - 6014 / 06014, 5015 / 05015,
--    9003 / 09003. Same gauges. Matching is done on a normalised serial (upper, alphanumerics
--    only, leading zeros stripped) so 6014 and 06014 are one asset rather than two.
--
-- B. TWO IDENTITY CALLS THAT ARE JUDGEMENT, NOT ARITHMETIC. Both are flagged in the loaded row's
--    remarks so they can be found and reversed.
--
--    THE PUSH-PULL GAUGE. The 2024-2025 sheet gives its serial as "RefMA 4617"; the 2025-2026
--    sheet gives "2809116082". Same description, same SN-500, same QA location, and only one
--    push-pull gauge has ever been on this list. "RefMA" reads as a reference number, not a
--    serial. Treated as ONE instrument, and the old string is recorded on the certificate.
--    If they are in fact two gauges, this puts one certificate on the wrong asset.
--
--    THE HALSTEN COUNTING SCALE. 231011032 on the old sheet, 23101132 on the new - nine digits
--    against eight, same brand, same model, same STORE location, and the old sheet notes it as a
--    NEW ISSUE on 24/7/25 which is when the new sheet's scale first appears. One of the two is a
--    transcription slip. Treated as ONE instrument; registering a second identical HALSTEN scale
--    would be the worse error, because it would sit on the form forever waiting for a calibration
--    that belongs to the other one.
--
-- C. THE OVERDUE SCALE MAY NOT BE OVERDUE. IT MAY BE SCRAPPED.
--    This is the one finding in this file that needs a person.
--
--    The WEIGHCOM counting scale, A08326347, is the instrument the alert currently chases as 32
--    days overdue. On the 2024-2025 sheet its PERSON column reads, in full:
--
--        OBSOLETE (24/7/25) BROKEN
--
--    and the row immediately below it registers the HALSTEN scale as GOOD CONDITION / NEW ISSUE
--    24/7/25. Read together those two rows say the WEIGHCOM broke and was replaced on the same
--    day. The 2025-2026 sheet nevertheless carries the WEIGHCOM forward as GOOD with a due date
--    of 24 JUL 2026 - which is what is now overdue.
--
--    This file does NOT act on that. It loads the 2024-2025 certificate with its condition
--    recorded as DAMAGED and the original text kept verbatim, so the contradiction is visible in
--    the instrument's history where somebody can settle it. Marking a live instrument obsolete on
--    the strength of an inference drawn from a superseded spreadsheet is precisely the kind of
--    silent record change this schema was built to prevent.
--
--    If QA confirms it was scrapped, one statement retires it and the alert stops chasing it:
--
--        update ext_cal_equipment
--           set status = 'OBSOLETE', condition = 'DAMAGED',
--               remarks = 'Broken and replaced by the HALSTEN scale on 24/07/2025 '
--                         '(per REC-QAS010-05 rev. 2024-2025). Retired <date> by <name>.',
--               updated_at = now(), updated_by = '<name>'
--         where equipment_code = 'CS' and serial_no = 'A08326347';
--
-- D. CRITERIA WERE REVISED, AND BOTH VERSIONS ARE KEPT.
--    The CMM was accepted against "± 0.01mm" in 2024 and against "± (1.9 + 4L/1000)µm" now.
--    VMM02 was "±0.001" and is now "±0.005mm". Each certificate stores the criteria that applied
--    on its own date, which is the whole reason ext_cal_event.criteria exists; the equipment's
--    current criteria are left alone.
--
-- E. WHAT IS NOT CARRIED ACROSS.
--    Location and equipment-code spellings changed between revisions - QA became QA/QC LAB,
--    VMM01 became VMM. The current spelling wins on the equipment row; the old sheet's wording is
--    not copied over it. Nothing on a historical certificate needs to know where the instrument
--    used to be kept.
--
--    The 2024-2025 sheet's last column is headed PERSON and holds condition text. It is mapped
--    onto the condition values this schema allows, with the original string kept verbatim in the
--    certificate's remarks, so nothing that was written down is lost to a lookup table.
--
-- Run AFTER sql/2026-08-25_external_calibration.sql, its seed, and the form-settings migration:
--   docker exec -i supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--       < sql/data/2026-08-25_external_calibration_2024_2025.sql

begin;

-- ---------------------------------------------------------------------
-- The sheet, verbatim
-- ---------------------------------------------------------------------
--
-- `retired` marks the three instruments that are on the 2024-2025 form and not on the 2025-2026
-- one. They are registered here as OBSOLETE: dropping off the next revision of a controlled
-- document is how an instrument is retired, and a record that simply stops mentioning something
-- cannot be audited.

create temporary table _s24 (
    no          int,
    equip       text,
    descr       text,
    serial_no   text,
    brand       text,
    location    text,
    cal_date    date,
    due_date    date,
    criteria    text,
    person      text,      -- the PERSON column, verbatim
    condition   text,      -- mapped onto this schema's allowed values
    retired     boolean default false,
    type_code   text
) on commit drop;

insert into _s24 (no, equip, descr, serial_no, brand, location, cal_date, due_date, criteria, person, condition, retired, type_code) values
 ( 1, 'BG',    'BLOCK GAUGE (10MM)',                      '09033',        'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.12µm\nVL : ± 0.10µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 2, 'BG',    'BLOCK GAUGE (25MM)',                      '6014',         'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.14µm\nVL : ± 0.10µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 3, 'BG',    'BLOCK GAUGE (50MM)',                      '5015',         'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.20µm\nVL : ± 0.10µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 4, 'BG',    'BLOCK GAUGE (75MM)',                      '05156',        'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.25µm\nVL : ± 0.12µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 5, 'BG',    'BLOCK GAUGE (100MM)',                     '9003',         'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.30µm\nVL : ± 0.12µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 6, 'BG',    'BLOCK GAUGE (150MM)',                     '07289',        'MICRON',      'QA',     '2021-12-07', '2026-12-07', E'DCL : ± 0.40µm\nVL : ± 0.14µm',            'GOOD CONDITION',            'GOOD',        false, 'BG'),
 ( 7, 'PG',    'DIAL PUSH PULL GAUGE',                    'RefMA 4617',   'SN-500',      'QA',     '2024-12-13', '2025-12-13', E'T (P) : ±0.05 kgf\nC (P) : ±0.05 kgf',    'GOOD CONDITION',            'GOOD',        false, 'PG'),
 ( 8, 'WM',    'DIGITAL PLATFORM SCALE (150kg X 0.01kg)', 'AL0947',       'MME',         'STORE',  '2025-07-26', '2026-07-26', '0.01kg',                                    'GOOD CONDITION',            'GOOD',        false, 'WM'),
 ( 9, 'CS',    'DIGITAL COUNTING SCALE (6000g X 0.2g)',   'A08326347',    'WEIGHCOM',    'STORE',  '2025-07-26', '2026-07-26', '0.2g',                                      'OBSOLETE (24/7/25) BROKEN', 'DAMAGED',     false, 'CS'),
 (10, 'CMM',   'COORDINATE MEASURING MACHINE',            '71426230',     'MITUTOYO',    'QA',     '2024-12-20', '2025-12-20', E'± 0.01mm',                                 'GOOD CONDITION',            'GOOD',        false, 'CMM'),
 (11, 'PP',    'PROFILE MEASURING',                       '760146',       'MITUTOYO',    'QA',     '2024-12-04', '2025-12-04', E'± 0.005mm',                                'GOOD CONDITION',            'GOOD',        false, 'PP'),
 (12, 'VMM01', 'VIDEO MEASURING MACHINE',                 'Q012010015',   'JATEN',       'QA',     '2025-02-06', '2026-02-06', E'± 0.005mm',                                'GOOD CONDITION',            'GOOD',        false, 'VMM'),
 (13, 'FS',    'DIGITAL FLOOR SCALE',                     '12/24/1888-04','MAGODA (E2G)','STORE',  '2024-12-16', '2025-12-15', '0.5kg',                                     'GOOD CONDITION',            'GOOD',        false, 'FS'),
 (14, 'TPG',   'M6 X 1-6H',                               '1004090309',   'INSIZE',      'QA',     '2024-12-13', '2025-12-13', E'MD : 6.010~6.032mm\nPD : 5.357~5.368mm',   'OUT OF SPEC',               'OUT OF SPEC', true,  'TPG'),
 (15, 'TPG',   'M14 X 2-6H',                              'MB 6067',      'BAKER',       'QA',     '2024-12-13', '2025-12-13', E'MD : 14.002~14.030mm\nPD : 12.696~12.724mm','OUT OF SPEC',              'OUT OF SPEC', true,  'TPG'),
 (16, 'DTI',   'DIAL TEST INDICATOR',                     'APAC37',       'MITUTOYO',    'QA',     '2024-12-27', '2025-12-27', E'3µm',                                      'GOOD CONDITION',            'GOOD',        true,  'DTI'),
 (17, 'VMM02', 'VIDEO MEASURING MACHINE',                 '2529115',      'JINUOSH',     'QA',     '2025-03-29', '2026-03-29', E'±0.001',                                   'GOOD CONDITION',            'GOOD',        false, 'VMM'),
 -- Due date equals the calibration date on the sheet. Loaded as written: a certificate valid for
 -- zero days is a clerical error on a signed form, and correcting it here would put a date in the
 -- record that nobody wrote. The constraint allows due = cal precisely so this can be recorded.
 (18, 'CS',    'DIGITAL COUNTING SCALE (6000g X 0.2g)',   '231011032',    'HALSTEN',     'STORE',  '2025-07-25', '2025-07-25', '0.2g',                                      E'GOOD CONDITION\nNEW ISSUE 24/7/25', 'GOOD', false, 'CS'),
 -- The lamp. N/A in both date columns, so there is no certificate to record - only the note that
 -- it was issued on 1/7/2025, which lands on the equipment row rather than inventing an event.
 (19, 'DLM',   'DIMMABLE LED MICROSCOPE LAMP',            'CX-HV4800',    'CHENXI',      'QA',     null,         null,         '20-160MM',                                  E'NEW ISSUE \n1/7/2025',      'GOOD',        false, 'DLM');

-- The DTI is the only type on the old form that the type lookup does not already know.
insert into ext_cal_equipment_type (code, name, sort_order) values ('DTI', 'Dial Test Indicator', 105)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------
--
-- Normalised serial: uppercase, alphanumerics only, leading zeros stripped. That is what makes
-- 6014 and 06014 one gauge, and 12/24/1888-04 match itself across two spellings of the separator.
-- Deliberately NOT fuzzy beyond that - it collapses transcription noise, not different serials.

create or replace function pg_temp.nser(s text) returns text language sql immutable as $$
  select ltrim(regexp_replace(upper(coalesce(s, '')), '[^A-Z0-9]', '', 'g'), '0')
$$;

create temporary table _map on commit drop as
select s.*,
       e.id as equipment_id
  from _s24 s
  left join ext_cal_equipment e
    -- The two judgement calls from section B are made here, by hand, rather than by loosening the
    -- serial rule for everything. Widening the match to catch them would also start matching
    -- things that are genuinely different.
    on  e.equipment_code = case s.equip when 'VMM01' then 'VMM' else s.equip end
    and (
         pg_temp.nser(e.serial_no) = pg_temp.nser(s.serial_no)
      or (s.no = 7  and e.equipment_code = 'PG' and e.brand = 'SN-500')      -- RefMA 4617
      -- like, not =: the brand is stored as 'HALSTEN (BC-6-E)' with the model in it, and an
      -- equality test against 'HALSTEN' matched nothing at all - which does not fail, it just
      -- quietly leaves one certificate unloaded.
      or (s.no = 18 and e.equipment_code = 'CS' and upper(e.brand) like 'HALSTEN%')
    );

-- Nothing may match two rows. If a future edit makes the rule ambiguous this stops the load
-- rather than silently attaching a certificate to whichever row sorted first.
do $$
declare n int;
begin
    select count(*) into n from (select no from _map group by no having count(*) > 1) x;
    if n > 0 then
        raise exception 'Ambiguous match for % row(s) of the 2024-2025 sheet - resolve before loading', n;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- The three instruments that were retired between revisions
-- ---------------------------------------------------------------------
--
-- sort_order 190+ puts them after the 18 current rows. They are OBSOLETE, so v_ext_cal_masterlist
-- gives them no line_no and they never reach the printed form or the alert - but their history is
-- readable, which is the entire point of registering them.

insert into ext_cal_equipment (
    equipment_code, type_code, description, serial_no, brand, location,
    accepted_criteria, condition, cal_interval_months, calibration_required,
    status, sort_order, remarks, created_by, updated_by)
select m.equip, m.type_code, m.descr, m.serial_no, m.brand, m.location,
       m.criteria, m.condition, 12, true,
       'OBSOLETE', 180 + m.no,
       'On REC-QAS010-05 rev. 2024-2025 and not on rev. 2025-2026. Registered as obsolete so its '
       || 'calibration history stays readable.',
       'MIGRATION 2024-2025', 'MIGRATION 2024-2025'
  from _map m
 where m.retired
   and m.equipment_id is null;

-- Pick the new rows up so their certificates can be attached below.
update _map m
   set equipment_id = e.id
  from ext_cal_equipment e
 where m.equipment_id is null
   and e.equipment_code = m.equip
   and e.description    = m.descr
   and coalesce(e.serial_no, '') = coalesce(m.serial_no, '');

-- ---------------------------------------------------------------------
-- The certificates
-- ---------------------------------------------------------------------
--
-- ON CONFLICT DO NOTHING, not DO UPDATE. Where a certificate for that instrument on that date
-- already exists it IS this certificate - the six block gauges, all six of them, appear on both
-- sheets with 7-Dec-21. Overwriting would rewrite a row the current seed already established.
--
-- lab is null: neither sheet ever recorded who did the calibration. cert_no likewise. Writing
-- "External Lab" would put a fact in the record that nobody stated.

insert into ext_cal_event (
    equipment_id, cal_date, due_date, cert_no, lab, result, condition, criteria,
    remarks, recorded_by)
select m.equipment_id, m.cal_date, m.due_date, null, null,
       case when m.condition in ('OUT OF SPEC', 'DAMAGED') then 'FAIL' end,
       m.condition, m.criteria,
       'Loaded from MASTERLIST EXTERNAL CALIBRATION 2024 - 2025.xlsx (item ' || m.no || '). '
       || 'Sheet recorded condition as: ' || replace(m.person, E'\n', ' / ') || '.'
       -- The two judgement calls, written onto the row they were made about, so anybody reading
       -- the instrument's history is told rather than having to find this file.
       -- coalesce on every branch. In SQL `text || NULL` is NULL, so a CASE with no ELSE that
       -- does not match does not append nothing - it erases the entire remark built above it.
       || coalesce(case when m.no = 7  then ' Sheet listed the serial as "RefMA 4617"; matched to '
                                || 'this gauge on description, brand and there being only one.' end, '')
       || coalesce(case when m.no = 18 then ' Sheet listed the serial as "231011032" against the '
                                || 'current "23101132"; treated as one scale.' end, '')
       || coalesce(case when m.no = 9  then ' NOTE: this sheet marks the instrument obsolete and '
                                || 'broken as of 24/7/25, which the current record contradicts.' end, '')
       || coalesce(case when m.cal_date = m.due_date then ' NOTE: the sheet gives the same date '
                                || 'for calibration and due - recorded as written.' end, ''),
       'MIGRATION 2024-2025'
  from _map m
 where m.equipment_id is not null
   and m.cal_date is not null
on conflict (equipment_id, cal_date) do update
   set due_date  = excluded.due_date,
       result    = excluded.result,
       condition = excluded.condition,
       criteria  = excluded.criteria,
       remarks   = excluded.remarks
 -- Only rows THIS file wrote. Where the clash is a block-gauge certificate the 2025-2026 seed
 -- already established, the guard is false and the row is left exactly as it is - which is the
 -- DO NOTHING this used to be, kept for the one case that needed it.
 where ext_cal_event.recorded_by = 'MIGRATION 2024-2025';

-- The lamp's issue note. Only where nothing has been written yet, so a remark somebody has since
-- typed on the page is never replaced by a line from a superseded spreadsheet.
update ext_cal_equipment e
   set remarks = 'Issued 1/7/2025 (per REC-QAS010-05 rev. 2024-2025).'
  from _map m
 where m.no = 19
   and m.equipment_id = e.id
   and (e.remarks is null or e.remarks = '');

commit;

-- =====================================================================
--  Verify
-- =====================================================================
--   select count(*) from ext_cal_equipment;                       -- 21  (18 + 3 retired)
--   select count(*) from ext_cal_equipment where status <> 'ACTIVE';  -- 3
--   select count(*) from ext_cal_event;                           -- 29  (17 + 12 new; 6 block
--                                                                 --      gauges deduped, lamp none)
--   -- the form still numbers 1..18 with no gaps:
--   select min(line_no), max(line_no), count(line_no) from v_ext_cal_masterlist;   -- 1, 18, 18
--   -- instruments that now have more than one certificate:
--   select equipment_code, serial_no, event_count from v_ext_cal_masterlist
--    where event_count > 1 order by equipment_code;
--   -- and the contradiction section C is about:
--   select cal_date, condition, remarks from ext_cal_event
--    where equipment_id = (select id from ext_cal_equipment
--                           where equipment_code='CS' and serial_no='A08326347')
--    order by cal_date;
