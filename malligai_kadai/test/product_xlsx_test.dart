import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:malligai_kadai/products/product_gateway.dart';
import 'package:malligai_kadai/products/product_xlsx.dart';

void main() {
  test('product workbook exports saved fields without product GST', () {
    final products = [
      const ProductItem(
        id: '1',
        name: 'Green & White Rice',
        sku: 'RICE-01',
        category: 'Grains',
        unit: 'kg',
        purchasePrice: '42.50',
        sellingPrice: '55.00',
        gstRate: '5.00',
      ),
      const ProductItem(
        id: '2',
        name: 'Tea',
        sku: '',
        category: 'Drinks',
        unit: 'packet',
        sellingPrice: '15.00',
        gstRate: '0.00',
      ),
    ];
    final archive = ZipDecoder().decodeBytes(encodeProductsXlsx(products));
    final sheet = XmlDocument.parse(
      utf8.decode(
        archive.findFile('xl/worksheets/sheet1.xml')!.content as List<int>,
      ),
    );
    final styles = XmlDocument.parse(
      utf8.decode(archive.findFile('xl/styles.xml')!.content as List<int>),
    );

    expect(sheet.findAllElements('col').length, 5);
    expect(
      sheet.findAllElements('autoFilter').single.getAttribute('ref'),
      'A1:F3',
    );
    final text = sheet.toXmlString();
    expect(text, contains('Green &amp; White Rice'));
    expect(text, contains('Product Code'));
    expect(text, contains('Purchase Price'));
    expect(text, contains('42.50'));
    expect(text, contains('55.00'));
    expect(text, isNot(contains('GST')));
    expect(
      styles.findAllElements('numFmt').single.getAttribute('formatCode'),
      '"₹"#,##0.00',
    );
  });
}
