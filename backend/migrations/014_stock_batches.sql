ALTER TABLE products
  ADD COLUMN IF NOT EXISTS opening_stock_quantity NUMERIC(12, 3) NOT NULL DEFAULT 0
  CHECK (opening_stock_quantity >= 0);

CREATE TABLE IF NOT EXISTS stock_batches (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  batch_type VARCHAR(16) NOT NULL CHECK (batch_type IN ('opening', 'purchase')),
  received_quantity NUMERIC(12, 3) NOT NULL CHECK (received_quantity >= 0),
  remaining_quantity NUMERIC(12, 3) NOT NULL CHECK (
    remaining_quantity >= 0 AND remaining_quantity <= received_quantity
  ),
  purchase_price NUMERIC(12, 2) NOT NULL CHECK (purchase_price >= 0),
  purchased_at TIMESTAMPTZ NOT NULL,
  created_by BIGINT REFERENCES app_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS stock_batches_one_opening_per_product_idx
  ON stock_batches (product_id) WHERE batch_type = 'opening';

CREATE INDEX IF NOT EXISTS stock_batches_fifo_idx
  ON stock_batches (product_id, purchased_at, id);

UPDATE products
SET opening_stock_quantity = stock_quantity
WHERE opening_stock_quantity = 0
  AND stock_quantity > 0
  AND NOT EXISTS (
    SELECT 1 FROM stock_batches batch WHERE batch.product_id = products.id
  );

ALTER TABLE inventory_movements
  ADD COLUMN IF NOT EXISTS stock_batch_id BIGINT
  REFERENCES stock_batches(id) ON DELETE RESTRICT;

INSERT INTO stock_batches (
  product_id, batch_type, received_quantity, remaining_quantity,
  purchase_price, purchased_at
)
SELECT id, 'opening', opening_stock_quantity, stock_quantity,
       purchase_price, created_at
FROM products
WHERE NOT EXISTS (
  SELECT 1 FROM stock_batches batch
  WHERE batch.product_id = products.id AND batch.batch_type = 'opening'
);

ALTER TABLE inventory_movements
  DROP CONSTRAINT IF EXISTS inventory_movements_reason_check;

ALTER TABLE inventory_movements
  ADD CONSTRAINT inventory_movements_reason_check
  CHECK (reason IN (
    'opening_balance', 'adjustment', 'sale', 'migration_baseline', 'new_purchase'
  ));
