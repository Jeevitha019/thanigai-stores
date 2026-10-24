CREATE SEQUENCE IF NOT EXISTS invoice_number_seq AS BIGINT START WITH 1;

CREATE TABLE IF NOT EXISTS invoices (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_number VARCHAR(32) NOT NULL UNIQUE,
  idempotency_key UUID NOT NULL UNIQUE,
  request_hash CHAR(64) NOT NULL,
  created_by BIGINT NOT NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  subtotal NUMERIC(14, 2) NOT NULL CHECK (subtotal >= 0),
  grand_total NUMERIC(14, 2) NOT NULL CHECK (grand_total >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS invoice_items (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
  product_id BIGINT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
  product_name_snapshot VARCHAR(160) NOT NULL,
  sku_snapshot VARCHAR(64) NOT NULL,
  unit_snapshot VARCHAR(16) NOT NULL,
  unit_price NUMERIC(12, 2) NOT NULL CHECK (unit_price > 0),
  quantity NUMERIC(12, 3) NOT NULL CHECK (quantity > 0),
  line_total NUMERIC(14, 2) NOT NULL CHECK (line_total >= 0)
);

CREATE INDEX IF NOT EXISTS invoices_created_at_idx
  ON invoices (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS invoice_items_invoice_id_idx
  ON invoice_items (invoice_id);
