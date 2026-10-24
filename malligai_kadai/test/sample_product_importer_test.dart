import 'package:flutter_test/flutter_test.dart';
import 'package:malligai_kadai/products/product_gateway.dart';
import 'package:malligai_kadai/products/sample_product_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads and validates all bundled Excel product rows', () async {
    final products = await SampleProductImporter.loadBundledProducts();

    expect(products, hasLength(88));
    expect(products.every((product) => product.name.isNotEmpty), isTrue);
    expect(products.every((product) => product.sku.startsWith('TS-')), isTrue);
    expect(
      products.every(
        (product) =>
            productUnits.contains(product.unit) &&
            double.parse(product.purchasePrice) >= 0 &&
            double.parse(product.sellingPrice) > 0 &&
            const [
              '0.00',
              '5.00',
              '12.00',
              '18.00',
              '28.00',
            ].contains(product.gstRate),
      ),
      isTrue,
    );
  });

  test('import plan skips existing and repeated products', () async {
    final products = await SampleProductImporter.loadBundledProducts();
    final existingDraft = products.first;
    final existing = ProductItem(
      id: '1',
      name: existingDraft.name,
      sku: existingDraft.sku,
      category: existingDraft.category,
      unit: existingDraft.unit,
      purchasePrice: existingDraft.purchasePrice,
      sellingPrice: existingDraft.sellingPrice,
      gstRate: existingDraft.gstRate,
    );

    final plan = SampleProductImporter.plan(
      [products.first, products.first, products[1]],
      [existing],
    );

    expect(plan.products, hasLength(1));
    expect(plan.products.single.name, products[1].name);
    expect(plan.duplicateCount, 2);
  });
}
