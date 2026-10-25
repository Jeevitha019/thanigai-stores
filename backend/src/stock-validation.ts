import { HttpError } from './auth';

function decimal(
  value: unknown,
  field: string,
  scale: number,
  minimum: number,
  maximum: number,
): string {
  if (typeof value !== 'string' && typeof value !== 'number') {
    throw new HttpError(400, `${field} must be a valid non-negative number.`);
  }
  const normalized = String(value).trim();
  if (!/^\d+(?:\.\d*)?$/.test(normalized)) {
    throw new HttpError(400, `${field} must be a valid non-negative number.`);
  }
  const numeric = Number(normalized);
  const fraction = normalized.split('.')[1] ?? '';
  if (
    !Number.isFinite(numeric) ||
    numeric < minimum ||
    numeric > maximum ||
    fraction.length > scale
  ) {
    throw new HttpError(
      400,
      `${field} must be between ${minimum} and ${maximum} with at most ${scale} decimal places.`,
    );
  }
  const [whole, decimals = ''] = normalized.split('.');
  return `${BigInt(whole).toString()}.${decimals.padEnd(scale, '0')}`;
}

export function validateOpeningStock(body: Record<string, unknown>) {
  return {
    quantity: decimal(
      body.quantity,
      'Opening stock quantity',
      3,
      0,
      999999999.999,
    ),
    purchasePrice: decimal(
      body.purchasePrice,
      'Purchase price',
      2,
      0,
      9999999999.99,
    ),
  };
}

export function validateStockPurchase(body: Record<string, unknown>) {
  const purchaseDate = body.purchaseDate;
  if (
    typeof purchaseDate !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}$/.test(purchaseDate)
  ) {
    throw new HttpError(400, 'Purchase date must be a valid date in YYYY-MM-DD format.');
  }
  const parsed = new Date(`${purchaseDate}T00:00:00.000Z`);
  if (
    !Number.isFinite(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== purchaseDate
  ) {
    throw new HttpError(400, 'Purchase date must be a valid date in YYYY-MM-DD format.');
  }
  return {
    quantity: decimal(
      body.quantity,
      'Purchase quantity',
      3,
      0.001,
      999999999.999,
    ),
    purchasePrice: decimal(
      body.purchasePrice,
      'Purchase price',
      2,
      0,
      9999999999.99,
    ),
    purchaseDate,
  };
}
