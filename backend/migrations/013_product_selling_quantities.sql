ALTER TABLE products
  ADD COLUMN IF NOT EXISTS selling_quantity NUMERIC(12, 3) NOT NULL DEFAULT 1.000
    CHECK (selling_quantity > 0);

ALTER TABLE invoice_items
  ALTER COLUMN unit_price TYPE NUMERIC(22, 6);
