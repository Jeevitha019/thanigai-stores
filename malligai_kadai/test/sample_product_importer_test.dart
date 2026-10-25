import 'dart:convert';

import 'package:archive/archive.dart';
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

  test('maps optional opening stock and stock unit columns', () {
    String cell(String column, String value) =>
        '<c r="$column" t="inlineStr"><is><t>$value</t></is></c>';
    final workbook = Archive()
      ..addFile(
        ArchiveFile.string(
          'xl/worksheets/sheet1.xml',
          '''<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
<row r="1">${cell('A', 'Category (English)')}${cell('B', 'Category (Tamil)')}${cell('C', 'Product Name (English)')}${cell('D', 'Product Name (Tamil)')}${cell('E', 'Unit')}${cell('F', 'Purchase Price (₹)')}${cell('G', 'Market Selling Price (₹)')}${cell('H', 'GST Rate (%)')}${cell('I', 'Opening/Old Stock Quantity')}${cell('J', 'Stock Unit')}</row>
<row r="2">${cell('A', 'Grains')}${cell('B', 'தானியங்கள்')}${cell('C', 'Rice')}${cell('D', 'அரிசி')}${cell('E', 'kg')}${cell('F', '50')}${cell('G', '80')}${cell('H', '5')}${cell('I', '100')}${cell('J', 'kg')}</row>
</sheetData></worksheet>''',
        ),
      );

    final products = SampleProductImporter.parse(ZipEncoder().encode(workbook)!);

    expect(products, hasLength(1));
    expect(products.single.unit, 'kg');
    expect(products.single.openingStockQuantity, '100.000');
    expect(products.single.purchasePrice, '50');
  });
}
