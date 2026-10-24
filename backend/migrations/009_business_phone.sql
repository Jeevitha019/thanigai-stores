ALTER TABLE shop_settings
  ADD COLUMN IF NOT EXISTS business_phone TEXT NOT NULL DEFAULT '';

ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS business_phone_snapshot TEXT NOT NULL DEFAULT '';
