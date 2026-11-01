import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malligai_kadai/products/product_gateway.dart';
import 'package:malligai_kadai/stocks/stock_management_screen.dart';

class _FakeStockGateway implements StockGateway {
  StockProduct product = const StockProduct(
    productId: '1',
    name: 'Besan Flour',
    sku: 'BESAN-1',
    unit: 'kg',
    openingQuantity: '100.000',
    openingRemainingQuantity: '100.000',
    openingPurchasePrice: '50.00',
    totalQuantity: '100.000',
    purchases: [],
  );

  String? savedOpeningQuantity;
  String? savedOpeningPrice;
  String? purchaseQuantity;
  String? purchasePrice;
  String? purchaseDate;

  @override
  Future<List<StockProduct>> loadStocks() async => [product];

  @override
  Future<StockProduct> updateOpeningStock(
    String productId,
    String quantity,
    String purchasePrice,
  ) async {
    savedOpeningQuantity = quantity;
    savedOpeningPrice = purchasePrice;
    product = StockProduct(
      productId: product.productId,
      name: product.name,
      sku: product.sku,
      unit: product.unit,
      openingQuantity: quantity,
      openingRemainingQuantity: quantity,
      openingPurchasePrice: purchasePrice,
      totalQuantity: quantity,
      purchases: product.purchases,
    );
    return product;
  }

  @override
  Future<StockProduct> receiveStockPurchase(
    String productId,
    String quantity,
    String purchasePrice,
    String purchaseDate,
  ) async {
    purchaseQuantity = quantity;
    this.purchasePrice = purchasePrice;
    this.purchaseDate = purchaseDate;
    final batch = StockBatch(
      id: '2',
      quantity: quantity,
      remainingQuantity: quantity,
      purchasePrice: purchasePrice,
      purchaseDate: purchaseDate,
    );
    product = StockProduct(
      productId: product.productId,
      name: product.name,
      sku: product.sku,
      unit: product.unit,
      openingQuantity: product.openingQuantity,
      openingRemainingQuantity: product.openingRemainingQuantity,
      openingPurchasePrice: product.openingPurchasePrice,
      totalQuantity:
          (double.parse(product.totalQuantity) + double.parse(quantity))
              .toStringAsFixed(3),
      purchases: [...product.purchases, batch],
    );
    return product;
  }
}

void main() {
  testWidgets('records separate opening and dated purchase stock', (
    tester,
  ) async {
    final gateway = _FakeStockGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: StockManagementScreen(gateway: gateway, canManage: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Old Stock'), findsOneWidget);
    expect(find.text('New Stock'), findsOneWidget);
    expect(find.textContaining('Old stock remaining: 100.000'), findsOneWidget);
    expect(find.textContaining('Available stock: 100.000'), findsOneWidget);
    expect(find.textContaining('kg'), findsNothing);
    await tester.enterText(find.byKey(const Key('openingQuantity_1')), '120');
    await tester.enterText(
      find.byKey(const Key('openingPurchasePrice_1')),
      '51.25',
    );
    await tester.tap(find.byKey(const Key('saveOpeningStock_1')));
    await tester.pumpAndSettle();
    expect(gateway.savedOpeningQuantity, '120');
    expect(gateway.savedOpeningPrice, '51.25');

    await tester.tap(find.text('New Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recordPurchase_1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('newStockQuantityField')),
      '100',
    );
    await tester.enterText(
      find.byKey(const Key('newStockPurchasePriceField')),
      '60.00',
    );
    await tester.tap(find.byKey(const Key('saveNewPurchaseButton')));
    await tester.pumpAndSettle();
    expect(gateway.purchaseQuantity, '100');
    expect(gateway.purchasePrice, '60.00');
    expect(gateway.purchaseDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(find.textContaining('100  •  ₹60.00'), findsOneWidget);
    expect(find.text('Available stock: 220.000'), findsOneWidget);
    expect(find.textContaining('kg'), findsNothing);
  });
}
