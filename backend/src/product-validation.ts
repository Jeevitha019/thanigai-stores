import { HttpError } from './auth';
import { productUnits, ProductInput, ProductUnit } from './product-types';

function requiredText(
  value: unknown,
  field: string,
  maxLength: number,
): string {
  if (typeof value !== 'string' || !value.trim()) {
    throw new HttpError(400, `${field} is required.`);
  }
  const result = value.trim();
  if (result.length > maxLength) {
    throw new HttpError(400, `${field} must be ${maxLength} characters or fewer.`);
  }
  return result;
}

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

  const stringValue = String(value).trim();
  if (!/^\d+(?:\.\d*)?$/.test(stringValue)) {
    throw new HttpError(400, `${field} must be a valid non-negative number.`);
  }
  const numericValue = Number(stringValue);
  const fractionalDigits = stringValue.split('.')[1]?.length ?? 0;

  if (
    !Number.isFinite(numericValue) ||
    numericValue < minimum ||
    numericValue > maximum ||
    fractionalDigits > scale
  ) {
    throw new HttpError(
      400,
      `${field} must be between ${minimum} and ${maximum} with at most ${scale} decimal places.`,
    );
  }

  const [integerPart, fractionPart = ''] = stringValue.split('.');
  const normalizedInteger = BigInt(integerPart).toString();
  return `${normalizedInteger}.${fractionPart.padEnd(scale, '0')}`;
}

export function validateProductInput(body: Record<string, unknown>): ProductInput {
  const unit = body.unit;
  if (
    typeof unit !== 'string' ||
    !productUnits.includes(unit as ProductUnit)
  ) {
    throw new HttpError(
      400,
      `Unit must be one of: ${productUnits.join(', ')}.`,
    );
  }

  const gstRate = decimal(body.gstRate, 'GST rate', 2, 0, 100);

  const sku =
    typeof body.sku === 'string' && body.sku.trim()
      ? requiredText(body.sku, 'Product code', 64)
      : null;

  return {
    name: requiredText(body.name, 'Name', 160),
    sku,
    category: requiredText(body.category, 'Category', 80),
    unit: unit as ProductUnit,
    purchasePrice: decimal(body.purchasePrice, 'Purchase price', 2, 0, 9999999999.99),
    sellingPrice: decimal(body.sellingPrice, 'Selling price', 2, 0.01, 9999999999.99),
    gstRate,
  };
}
