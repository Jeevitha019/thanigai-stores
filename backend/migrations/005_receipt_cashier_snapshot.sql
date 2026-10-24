ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS cashier_name_snapshot VARCHAR(64) NOT NULL DEFAULT 'Unknown';

UPDATE invoices AS invoice
SET cashier_name_snapshot = app_user.username
FROM app_users AS app_user
WHERE app_user.id = invoice.created_by
  AND invoice.cashier_name_snapshot = 'Unknown';
