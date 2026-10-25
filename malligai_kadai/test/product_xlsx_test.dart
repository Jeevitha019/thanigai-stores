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
        sellingQuantity: '0.500',
        openingStockQuantity: '100.000',
        stockQuantity: '100.000',
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

    expect(sheet.findAllElements('col').length, 7);
    expect(
      sheet.findAllElements('autoFilter').single.getAttribute('ref'),
      'A1:I3',
    );
    final text = sheet.toXmlString();
    expect(text, contains('Green &amp; White Rice'));
    expect(text, contains('Product Code'));
    expect(text, contains('Purchase Price'));
    expect(text, contains('Opening/Old Stock Quantity'));
    expect(text, contains('Stock Unit'));
    expect(text, contains('100.000'));
    expect(text, contains('42.50'));
    expect(text, contains('55.00'));
    expect(text, contains('>kg</t>'));
    expect(text, contains('>0.500</v>'));
    expect(
      sheet
          .findAllElements('c')
          .singleWhere((cell) => cell.getAttribute('r') == 'D2')
          .findAllElements('t')
          .single
          .innerText,
      'kg',
    );
    expect(
      sheet
          .findAllElements('c')
          .singleWhere((cell) => cell.getAttribute('r') == 'E2')
          .findElements('v')
          .single
          .innerText,
      '42.50',
    );
    expect(
      sheet
          .findAllElements('c')
          .singleWhere((cell) => cell.getAttribute('r') == 'F2')
          .findElements('v')
          .single
          .innerText,
      '55.00',
    );
    expect(
      sheet
          .findAllElements('c')
          .singleWhere((cell) => cell.getAttribute('r') == 'G2')
          .findElements('v')
          .single
          .innerText,
      '100.000',
    );
    expect(
      sheet
          .findAllElements('c')
          .singleWhere((cell) => cell.getAttribute('r') == 'H2')
          .findAllElements('t')
          .single
          .innerText,
      'kg',
    );
    expect(text, isNot(contains('GST')));
    expect(
      styles.findAllElements('numFmt').single.getAttribute('formatCode'),
      '"₹"#,##0.00',
    );
  });
}
