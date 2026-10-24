import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'product_gateway.dart';

Uint8List encodeProductsXlsx(List<ProductItem> products) {
  final rows = <String>[
    for (var index = 0; index < products.length; index++)
      _productRow(products[index], index + 2),
  ];
  final rowCount = products.length + 1;
  final worksheet =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<dimension ref="A1:F$rowCount"/>
<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
<cols><col min="1" max="1" width="32" customWidth="1"/><col min="2" max="2" width="20" customWidth="1"/><col min="3" max="3" width="24" customWidth="1"/><col min="4" max="4" width="14" customWidth="1"/><col min="5" max="6" width="18" customWidth="1"/></cols>
<sheetData><row r="1">${_textCell('A', 1, 'Product Name', style: 1)}${_textCell('B', 1, 'Product Code', style: 1)}${_textCell('C', 1, 'Category', style: 1)}${_textCell('D', 1, 'Unit', style: 1)}${_textCell('E', 1, 'Purchase Price', style: 1)}${_textCell('F', 1, 'Selling Price', style: 1)}</row>${rows.join()}
</sheetData><autoFilter ref="A1:F$rowCount"/>
</worksheet>''';
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Products" sheetId="1" r:id="rId1"/></sheets></workbook>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/styles.xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="1"><numFmt numFmtId="164" formatCode="&quot;&#x20B9;&quot;#,##0.00"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>''',
      ),
    )
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', worksheet));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _productRow(ProductItem product, int row) =>
    '<row r="$row">'
    '${_textCell('A', row, product.name)}'
    '${_textCell('B', row, product.sku)}'
    '${_textCell('C', row, product.category)}'
    '${_textCell('D', row, product.unit)}'
    '${_priceCell('E', row, product.purchasePrice, optional: true)}'
    '${_priceCell('F', row, product.sellingPrice)}'
    '</row>';

String _textCell(String column, int row, String value, {int style = 0}) =>
    '<c r="$column$row" t="inlineStr" s="$style"><is><t xml:space="preserve">${_xml(value)}</t></is></c>';

String _priceCell(
  String column,
  int row,
  String? value, {
  bool optional = false,
}) {
  if (value == null || value.trim().isEmpty) {
    if (optional) return '';
    throw const FormatException('A product price is missing.');
  }
  final normalized = value.trim();
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(normalized)) {
    throw const FormatException('A product price is not a valid number.');
  }
  return '<c r="$column$row" s="2"><v>$normalized</v></c>';
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
