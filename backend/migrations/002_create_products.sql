CREATE TABLE IF NOT EXISTS products (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name VARCHAR(160) NOT NULL,
  sku VARCHAR(64) NOT NULL,
  category VARCHAR(80) NOT NULL,
  unit VARCHAR(16) NOT NULL CHECK (
    unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet')
  ),
  purchase_price NUMERIC(12, 2) NOT NULL CHECK (purchase_price >= 0),
  selling_price NUMERIC(12, 2) NOT NULL CHECK (selling_price > 0),
  stock_quantity NUMERIC(12, 3) NOT NULL CHECK (stock_quantity >= 0),
  low_stock_threshold NUMERIC(12, 3) NOT NULL CHECK (low_stock_threshold >= 0),
  gst_rate NUMERIC(5, 2) NOT NULL CHECK (gst_rate >= 0 AND gst_rate <= 100),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS products_sku_lower_unique
  ON products (LOWER(sku));

CREATE INDEX IF NOT EXISTS products_active_name_lower_idx
  ON products (LOWER(name))
  WHERE is_active = TRUE;
