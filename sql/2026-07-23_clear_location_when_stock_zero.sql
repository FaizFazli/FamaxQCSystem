-- ============================================================================
-- Release rack locations on inventory items that are already at zero stock
-- Run once in the Supabase SQL editor (transactional; safe to re-run).
--
-- The app now clears inventory.item_location whenever a transaction (or a
-- manual edit) brings an item to 0 pcs - see saveToStoreRecord in
-- store_record.html and computeStock / updateStock in inventory_dashboard.html.
-- That only applies going forward, so rows that were already sitting at zero
-- still point at racks they no longer occupy. This backfills them.
--
-- inventory.item_location is JSONB holding an array of location strings, so
-- "cleared" is '[]'::jsonb - NOT '{}', which is an empty JSON *object*, and
-- not NULL, so the shape stays consistent with what the app writes.
--
-- The dashboard already displays "-" for any item at zero, so this changes
-- stored data only - the on-screen result is the same either way.
-- ============================================================================

BEGIN;

-- 1. Keep the old values so this is reversible (see the rollback at the end).
--    Dropped by hand once the result has been eyeballed.
CREATE TABLE IF NOT EXISTS public.bk_item_location_20260723 AS
SELECT id, item_location, available_pcs
  FROM public.inventory
 WHERE COALESCE(available_pcs, 0) <= 0
   AND item_location IS NOT NULL
   AND item_location <> '[]'::jsonb;

-- 2. Preview - what is about to be released.
SELECT id, barcode, customer, product_name, available_pcs, item_location
  FROM public.inventory
 WHERE COALESCE(available_pcs, 0) <= 0
   AND item_location IS NOT NULL
   AND item_location <> '[]'::jsonb
 ORDER BY customer, barcode;

-- 3. Clear them.
--    updated_at is deliberately left alone: this is a data cleanup, not stock
--    movement, and bumping it would misreport when the item last moved.
UPDATE public.inventory
   SET item_location = '[]'::jsonb
 WHERE COALESCE(available_pcs, 0) <= 0
   AND item_location IS NOT NULL
   AND item_location <> '[]'::jsonb;

COMMIT;

-- 4. Verify - both counts should be 0.
SELECT count(*) FILTER (
         WHERE COALESCE(available_pcs, 0) <= 0
           AND item_location IS NOT NULL
           AND item_location <> '[]'::jsonb
       ) AS zero_stock_still_holding_a_rack,
       count(*) FILTER (
         WHERE COALESCE(available_pcs, 0) > 0
           AND (item_location IS NULL OR item_location = '[]'::jsonb)
       ) AS in_stock_with_no_rack   -- pre-existing gaps, not caused by this script
  FROM public.inventory;

-- ----------------------------------------------------------------------------
-- ROLLBACK (only if needed, and only before the backup table is dropped):
--
-- UPDATE public.inventory i
--    SET item_location = b.item_location
--   FROM public.bk_item_location_20260723 b
--  WHERE b.id = i.id;
--
-- Once satisfied:
-- DROP TABLE public.bk_item_location_20260723;
-- ----------------------------------------------------------------------------
