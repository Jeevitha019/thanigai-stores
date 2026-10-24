CREATE TABLE IF NOT EXISTS shop_settings (
  id SMALLINT PRIMARY KEY CHECK (id = 1),
  gst_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  price_mode VARCHAR(12) NOT NULL DEFAULT 'exclusive'
    CHECK (price_mode IN ('inclusive', 'exclusive')),
  state_code CHAR(2) NOT NULL DEFAULT '00'
    CHECK (state_code ~ '^[0-9]{2}$'),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO shop_settings (id, gst_enabled, price_mode, state_code)
VALUES (1, FALSE, 'exclusive', '00')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE products
  ADD CONSTRAINT products_gst_rate_standard_check
  CHECK (gst_rate IN (0, 5, 12, 18, 28)) NOT VALID;

ALTER TABLE products
  VALIDATE CONSTRAINT products_gst_rate_standard_check;

ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS request_hash CHAR(64),
  ADD COLUMN IF NOT EXISTS gst_enabled_snapshot BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS price_mode_snapshot VARCHAR(12) NOT NULL DEFAULT 'exclusive',
  ADD COLUMN IF NOT EXISTS shop_state_code_snapshot CHAR(2) NOT NULL DEFAULT '00',
  ADD COLUMN IF NOT EXISTS sale_state_code_snapshot CHAR(2) NOT NULL DEFAULT '00',
  ADD COLUMN IF NOT EXISTS taxable_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cgst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sgst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS igst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_tax NUMERIC(14, 2) NOT NULL DEFAULT 0;

UPDATE invoices SET request_hash = repeat('0', 64) WHERE request_hash IS NULL;
ALTER TABLE invoices ALTER COLUMN request_hash SET NOT NULL;

ALTER TABLE invoice_items
  ADD COLUMN IF NOT EXISTS gst_rate_snapshot NUMERIC(5, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS taxable_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cgst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sgst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS igst_amount NUMERIC(14, 2) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS invoice_payments (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_id BIGINT NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
  method VARCHAR(8) NOT NULL CHECK (method IN ('cash', 'upi', 'card')),
  amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (invoice_id, method)
);

CREATE INDEX IF NOT EXISTS invoice_payments_invoice_id_idx
  ON invoice_payments (invoice_id);
