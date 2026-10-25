export interface StockBatch {
  id: string;
  type: 'opening' | 'purchase';
  quantity: string;
  remainingQuantity: string;
  purchasePrice: string;
  purchaseDate: string;
}

export interface StockProduct {
  productId: string;
  name: string;
  sku: string | null;
  unit: string;
  openingQuantity: string;
  openingRemainingQuantity: string;
  openingPurchasePrice: string;
  totalQuantity: string;
  purchases: StockBatch[];
}

export interface StockRepository {
  list(): Promise<StockProduct[]>;
  setOpeningStock(
    productId: string,
    quantity: string,
    purchasePrice: string,
    actorId: string,
  ): Promise<StockProduct | null>;
  receivePurchase(
    productId: string,
    quantity: string,
    purchasePrice: string,
    purchaseDate: string,
    actorId: string,
  ): Promise<StockProduct | null>;
}
