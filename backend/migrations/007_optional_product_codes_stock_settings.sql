ALTER TABLE products
  ALTER COLUMN sku DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'shop_settings'
      AND column_name = 'stock_tracking_enabled'
  ) THEN
    ALTER TABLE shop_settings
      ADD COLUMN stock_tracking_enabled BOOLEAN NOT NULL DEFAULT FALSE;

    IF EXISTS (SELECT 1 FROM products) OR EXISTS (SELECT 1 FROM invoices) THEN
      UPDATE shop_settings SET stock_tracking_enabled = TRUE;
    END IF;
  END IF;
END $$;
