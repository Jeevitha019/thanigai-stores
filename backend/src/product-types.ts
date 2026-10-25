export const productUnits = [
  'kg',
  'g',
  'litre',
  'ml',
  'piece',
  'packet',
] as const;

export type ProductUnit = (typeof productUnits)[number];

export interface Product {
  id: string;
  name: string;
  sku: string | null;
  category: string;
  unit: ProductUnit;
  purchasePrice: string;
  sellingPrice: string;
  sellingQuantity: string;
  openingStockQuantity?: string;
  stockQuantity?: string;
  gstRate: string;
  createdAt: string;
  updatedAt: string;
}

export interface ProductInput {
  name: string;
  sku: string | null;
  category: string;
  unit: ProductUnit;
  purchasePrice: string;
  sellingPrice: string;
  sellingQuantity: string;
  openingStockQuantity?: string;
  gstRate: string;
}

export interface ProductRepository {
  list(search: string): Promise<Product[]>;
  findById(id: string): Promise<Product | null>;
  create(input: ProductInput, actorId?: string): Promise<Product>;
  update(id: string, input: ProductInput, actorId?: string): Promise<Product | null>;
  softDelete(id: string, actorId?: string): Promise<boolean>;
}
