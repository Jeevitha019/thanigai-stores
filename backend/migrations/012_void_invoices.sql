ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS voided_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS voided_by BIGINT REFERENCES app_users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS void_reason VARCHAR(255);

ALTER TABLE invoices
  ADD CONSTRAINT invoices_void_state_check
  CHECK (
    (voided_at IS NULL AND voided_by IS NULL AND void_reason IS NULL) OR
    (voided_at IS NOT NULL AND void_reason IS NOT NULL)
  );
