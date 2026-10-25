import { HttpError } from './auth';
import {
  CreateInvoiceRequest,
  PaymentInput,
  PaymentMethod,
  RequestedInvoiceItem,
} from './billing-types';

export function validateInvoiceRequest(
  body: Record<string, unknown>,
): CreateInvoiceRequest {
  const idempotencyKey = body.idempotencyKey;
  if (
    typeof idempotencyKey !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      idempotencyKey,
    )
  ) {
    throw new HttpError(400, 'A valid idempotency key is required.');
  }

  if (!Array.isArray(body.items) || body.items.length === 0) {
    throw new HttpError(400, 'At least one invoice item is required.');
  }
  if (
    typeof body.saleStateCode !== 'string' ||
    !/^\d{2}$/.test(body.saleStateCode)
  ) {
    throw new HttpError(400, 'A valid two-digit sale state code is required.');
  }
  const discountAmount = validateInvoiceAmount(
    body.discountAmount ?? '0.00',
    'Discount',
  );
  const gstAmount = validateInvoiceAmount(body.gstAmount ?? '0.00', 'GST');
  if (gstAmount !== '0.00') {
    throw new HttpError(400, 'GST is calculated from the saved Settings rate.');
  }

  if (!Array.isArray(body.payments) || body.payments.length === 0 || body.payments.length > 3) {
    throw new HttpError(400, 'Provide one payment method or a split of up to three methods.');
  }
  const seenMethods = new Set<string>();
  const payments: PaymentInput[] = body.payments.map((payment) => {
    if (payment === null || typeof payment !== 'object' || Array.isArray(payment)) {
      throw new HttpError(400, 'Each payment must be an object.');
    }
    const value = payment as Record<string, unknown>;
    if (
      value.method !== 'cash' &&
      value.method !== 'upi' &&
      value.method !== 'card'
    ) {
      throw new HttpError(400, 'Payment method must be cash, UPI, or card.');
    }
    const method = value.method as PaymentMethod;
    if (seenMethods.has(method)) {
      throw new HttpError(400, 'Each payment method can only be used once.');
    }
    seenMethods.add(method);
    if (
      typeof value.amount !== 'string' ||
      !/^\d+(?:\.\d{0,2})?$/.test(value.amount) ||
      priceToCents(value.amount) <= 0n
    ) {
      throw new HttpError(400, 'Payment amount must be greater than zero with at most 2 decimal places.');
    }
    return {
      method,
      amount: centsToMoney(priceToCents(value.amount)),
    };
  });
  if (body.items.length > 100) {
    throw new HttpError(400, 'An invoice cannot contain more than 100 items.');
  }

  const seenProducts = new Set<string>();
  const items: RequestedInvoiceItem[] = body.items.map((item) => {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) {
      throw new HttpError(400, 'Each invoice item must be an object.');
    }
    const value = item as Record<string, unknown>;
    if (
      typeof value.productId !== 'string' ||
      !/^[1-9]\d*$/.test(value.productId)
    ) {
      throw new HttpError(400, 'Each item must have a valid product ID.');
    }
    if (seenProducts.has(value.productId)) {
      throw new HttpError(400, 'Each product can only appear once in the cart.');
    }
    seenProducts.add(value.productId);

    if (
      typeof value.quantity !== 'string' ||
      !/^\d+(?:\.\d{0,3})?$/.test(value.quantity)
    ) {
      throw new HttpError(
        400,
        'Quantity must be a positive number with at most 3 decimal places.',
      );
    }
    const quantityMilli = quantityToMilli(value.quantity);
    if (quantityMilli <= 0n) {
      throw new HttpError(400, 'Quantity must be greater than zero.');
    }
    if (quantityMilli > 999999999999n) {
      throw new HttpError(400, 'Quantity is too large.');
    }

    let unitPrice: string | undefined;
    if (value.unitPrice !== undefined) {
      if (
        typeof value.unitPrice !== 'string' ||
        !/^\d+(?:\.\d{0,2})?$/.test(value.unitPrice) ||
        priceToCents(value.unitPrice) <= 0n ||
        priceToCents(value.unitPrice) > 99999999999999n
      ) {
        throw new HttpError(
          400,
          'Product amount must be positive with at most 2 decimal places.',
        );
      }
      unitPrice = centsToMoney(priceToCents(value.unitPrice));
    }

    return {
      productId: value.productId,
      quantity: milliToQuantity(quantityMilli),
      ...(unitPrice === undefined ? {} : { unitPrice }),
    };
  });

  return {
    idempotencyKey,
    items,
    saleStateCode: body.saleStateCode,
    discountAmount,
    gstAmount,
    payments,
  };
}

function validateInvoiceAmount(value: unknown, label: string): string {
  if (
    typeof value !== 'string' ||
    !/^\d+(?:\.\d{0,2})?$/.test(value) ||
    priceToCents(value) > 99999999999999n
  ) {
    throw new HttpError(
      400,
      `${label} amount must be non-negative with at most 2 decimal places.`,
    );
  }
  return centsToMoney(priceToCents(value));
}

export function quantityToMilli(quantity: string): bigint {
  const [integerPart, fractionalPart = ''] = quantity.split('.');
  return BigInt(integerPart) * 1000n + BigInt(fractionalPart.padEnd(3, '0'));
}

export function milliToQuantity(quantity: bigint): string {
  const sign = quantity < 0n ? '-' : '';
  const absolute = quantity < 0n ? -quantity : quantity;
  return `${sign}${absolute / 1000n}.${(absolute % 1000n)
    .toString()
    .padStart(3, '0')}`;
}

export function priceToCents(price: string): bigint {
  const [integerPart, fractionalPart = ''] = price.split('.');
  return BigInt(integerPart) * 100n + BigInt(fractionalPart.padEnd(2, '0'));
}

export function centsToMoney(cents: bigint): string {
  return `${cents / 100n}.${(cents % 100n).toString().padStart(2, '0')}`;
}

export function lineTotalCents(unitPrice: string, quantity: string): bigint {
  const product = priceToCents(unitPrice) * quantityToMilli(quantity);
  return (product + 500n) / 1000n;
}

export function configuredLineTotalCents(
  unitPrice: string,
  quantity: string,
  sellingQuantity: string,
): bigint {
  const configuredMilli = quantityToMilli(sellingQuantity);
  if (configuredMilli <= 0n) {
    throw new RangeError('Configured selling quantity must be positive.');
  }
  const amount = priceToCents(unitPrice) * quantityToMilli(quantity);
  return (amount + configuredMilli / 2n) / configuredMilli;
}

export function unitPriceMicros(
  unitPrice: string,
  sellingQuantity: string,
): bigint {
  const configuredMilli = quantityToMilli(sellingQuantity);
  if (configuredMilli <= 0n) {
    throw new RangeError('Configured selling quantity must be positive.');
  }
  return (
    priceToCents(unitPrice) * 10_000_000n +
    configuredMilli / 2n
  ) / configuredMilli;
}

export function microsToUnitPrice(micros: bigint): string {
  return `${micros / 1_000_000n}.${(micros % 1_000_000n)
    .toString()
    .padStart(6, '0')}`;
}

export interface ItemTaxBreakdown {
  lineTotalCents: bigint;
  taxableCents: bigint;
  cgstCents: bigint;
  sgstCents: bigint;
  igstCents: bigint;
  taxCents: bigint;
}

export function calculateItemTax(
  lineTotal: bigint,
  ratePercent: string,
  enabled: boolean,
  inclusive: boolean,
  interstate: boolean,
): ItemTaxBreakdown {
  if (!enabled || priceToCents(ratePercent) === 0n) {
    return {
      lineTotalCents: lineTotal,
      taxableCents: lineTotal,
      cgstCents: 0n,
      sgstCents: 0n,
      igstCents: 0n,
      taxCents: 0n,
    };
  }

  const rateHundredths = priceToCents(ratePercent);
  const taxableCents = inclusive
    ? (lineTotal * 10000n + (10000n + rateHundredths) / 2n) /
      (10000n + rateHundredths)
    : lineTotal;
  const taxCents = inclusive
    ? lineTotal - taxableCents
    : (taxableCents * rateHundredths + 5000n) / 10000n;
  const finalLineTotal = inclusive ? lineTotal : taxableCents + taxCents;

  if (interstate) {
    return {
      lineTotalCents: finalLineTotal,
      taxableCents,
      cgstCents: 0n,
      sgstCents: 0n,
      igstCents: taxCents,
      taxCents,
    };
  }

  const cgstCents = (taxCents + 1n) / 2n;
  return {
    lineTotalCents: finalLineTotal,
    taxableCents,
    cgstCents,
    sgstCents: taxCents - cgstCents,
    igstCents: 0n,
    taxCents,
  };
}

export function validateShopStateCode(value: unknown): string {
  if (typeof value !== 'string' || !/^\d{2}$/.test(value)) {
    throw new HttpError(400, 'Shop state code must contain exactly two digits.');
  }
  return value;
}

export function validateGstSettings(body: Record<string, unknown>) {
  if (typeof body.gstEnabled !== 'boolean') {
    throw new HttpError(400, 'GST enabled must be true or false.');
  }
  if (
    typeof body.gstRate !== 'string' ||
    !/^\d+(?:\.\d{1,2})?$/.test(body.gstRate) ||
    priceToCents(body.gstRate) > 10000n
  ) {
    throw new HttpError(400, 'GST rate must be between 0 and 100 percent.');
  }
  if (body.priceMode !== 'inclusive' && body.priceMode !== 'exclusive') {
    throw new HttpError(400, 'Price mode must be inclusive or exclusive.');
  }
  const stateCode = validateShopStateCode(body.stateCode);
  if (body.gstEnabled && stateCode === '00') {
    throw new HttpError(400, 'Set the shop state code before enabling GST.');
  }
  const businessName = validateBusinessText(
    body.businessName ?? 'Thanigai Stores',
    'Business name',
    160,
  );
  const businessAddress = validateBusinessText(
    body.businessAddress ?? '',
    'Business address',
    1000,
    true,
  );
  const businessPhone = validateBusinessText(
    body.businessPhone ?? '',
    'Business phone',
    64,
    true,
  );
  const gstin =
    typeof body.gstin === 'string'
      ? body.gstin.trim().toUpperCase()
      : body.gstin ?? '';
  if (
    typeof gstin !== 'string' ||
    gstin.length > 15 ||
    (gstin !== '' && !/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(gstin))
  ) {
    throw new HttpError(400, 'GSTIN must be a valid 15-character GST identification number.');
  }
  return {
    gstEnabled: body.gstEnabled,
    gstRate: centsToMoney(priceToCents(body.gstRate)),
    priceMode: body.priceMode,
    stateCode,
    businessName,
    businessAddress,
    businessPhone,
    gstin,
  } as const;
}

function validateBusinessText(
  value: unknown,
  label: string,
  maxLength: number,
  allowEmpty = false,
): string {
  if (
    typeof value !== 'string' ||
    (!allowEmpty && value.trim().length === 0) ||
    value.length > maxLength
  ) {
    throw new HttpError(
      400,
      `${label} must contain ${allowEmpty ? '0' : '1'}-${maxLength} characters.`,
    );
  }
  return value.trim();
}
