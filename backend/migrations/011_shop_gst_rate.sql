ALTER TABLE shop_settings
  ADD COLUMN IF NOT EXISTS gst_rate NUMERIC(5, 2) NOT NULL DEFAULT 0
    CHECK (gst_rate >= 0 AND gst_rate <= 100);
