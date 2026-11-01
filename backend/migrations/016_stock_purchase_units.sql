ALTER TABLE stock_batches
  ADD COLUMN IF NOT EXISTS purchase_quantity NUMERIC(12, 3),
  ADD COLUMN IF NOT EXISTS purchase_unit VARCHAR(16);

UPDATE stock_batches batch
SET purchase_quantity = batch.received_quantity,
    purchase_unit = product.unit
FROM products product
WHERE product.id = batch.product_id
  AND (batch.purchase_quantity IS NULL OR batch.purchase_unit IS NULL);

ALTER TABLE stock_batches
  ALTER COLUMN purchase_quantity SET NOT NULL,
  ALTER COLUMN purchase_unit SET NOT NULL;

ALTER TABLE stock_batches
  DROP CONSTRAINT IF EXISTS stock_batches_purchase_quantity_check,
  DROP CONSTRAINT IF EXISTS stock_batches_purchase_unit_check;

ALTER TABLE stock_batches
  ADD CONSTRAINT stock_batches_purchase_quantity_check
    CHECK (purchase_quantity >= 0),
  ADD CONSTRAINT stock_batches_purchase_unit_check
    CHECK (purchase_unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet'));
