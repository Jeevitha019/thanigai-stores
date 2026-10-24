CREATE TABLE IF NOT EXISTS inventory_movements (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  change_quantity NUMERIC(12, 3) NOT NULL,
  reason VARCHAR(32) NOT NULL CHECK (
    reason IN ('opening_balance', 'adjustment', 'sale', 'migration_baseline')
  ),
  invoice_id BIGINT REFERENCES invoices(id) ON DELETE RESTRICT,
  created_by BIGINT REFERENCES app_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (reason = 'migration_baseline' OR change_quantity <> 0),
  CHECK ((reason = 'sale' AND invoice_id IS NOT NULL) OR
         (reason <> 'sale' AND invoice_id IS NULL))
);

CREATE INDEX IF NOT EXISTS inventory_movements_product_created_idx
  ON inventory_movements (product_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS inventory_movements_created_idx
  ON inventory_movements (created_at DESC, id DESC);

INSERT INTO inventory_movements (product_id, change_quantity, reason, created_at)
SELECT id, stock_quantity, 'migration_baseline', NOW()
FROM products
WHERE NOT EXISTS (
  SELECT 1 FROM inventory_movements movement WHERE movement.product_id = products.id
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id BIGINT REFERENCES app_users(id) ON DELETE SET NULL,
  action VARCHAR(64) NOT NULL,
  entity_type VARCHAR(32) NOT NULL,
  entity_id VARCHAR(64),
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS audit_logs_created_idx
  ON audit_logs (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS audit_logs_actor_created_idx
  ON audit_logs (actor_id, created_at DESC, id DESC);
