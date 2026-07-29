-- 2026-07-29  Re-Inspection: link a RE-INSPECTION record to the reject row it clears.
--
-- A re-inspection is stored as an ordinary "InspectionRecord" row with
-- Inspection_Type = 'RE-INSPECTION'. Until now the Rejected Product Record had to guess
-- which reject row a re-inspection belonged to by matching JO_Number|Part_Name|Parameter
-- and comparing timestamps, which mis-attributes when one JO/part/parameter has several
-- reject rows in the same month.
--
-- parent_record_id makes that link explicit. It logically references "InspectionRecord"(id);
-- no FK, matching the app's denormalized text-key convention (see TravelerSignoff).
-- The report keeps the old fuzzy match as a fallback so pre-migration rows still render.
--
-- The child row carries its own Remark = [{description, quantity}] naming exactly which
-- defect lines were re-inspected, and AcceptQty = the total re-inspected OK quantity.

alter table "InspectionRecord" add column if not exists parent_record_id bigint;

create index if not exists idx_inspectionrecord_parent on "InspectionRecord" (parent_record_id);

-- PostgREST exposes the column automatically once added; no server change required.
