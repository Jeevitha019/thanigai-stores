import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'reports_gateway.dart';

class _WorkbookCell {
  const _WorkbookCell.text(this.value, {this.style = 0});
  const _WorkbookCell.number(this.value, {this.style = 0});

  final Object value;
  final int style;
}

Uint8List encodeSalesReportXlsx(SalesReportData report) {
  final summaryRows = <List<_WorkbookCell?>>[
    [const _WorkbookCell.text('Thanigai Stores sales report', style: 4)],
    [
      const _WorkbookCell.text('Period'),
      _WorkbookCell.text('${report.startDate} to ${report.endDate}'),
    ],
    [const _WorkbookCell.text('Total sales'), _moneyCell(report.totalSales)],
    [
      const _WorkbookCell.text('Invoice count'),
      _WorkbookCell.number(report.invoiceCount),
    ],
    [],
    [
      const _WorkbookCell.text('Payment method', style: 4),
      const _WorkbookCell.text('Invoice count', style: 4),
      const _WorkbookCell.text('Amount', style: 4),
    ],
    for (final payment in report.paymentSummary)
      [
        _WorkbookCell.text(payment.method),
        _WorkbookCell.number(payment.invoiceCount),
        _moneyCell(payment.amount),
      ],
  ];

  final orderRows = <List<_WorkbookCell?>>[
    [
      const _WorkbookCell.text('Order No', style: 5),
      const _WorkbookCell.text('Date', style: 5),
      const _WorkbookCell.text('Time', style: 5),
      const _WorkbookCell.text('Paid At', style: 5),
      const _WorkbookCell.text('Table', style: 5),
      const _WorkbookCell.text('Items', style: 5),
      const _WorkbookCell.text('Subtotal', style: 5),
      const _WorkbookCell.text('Discount', style: 5),
      const _WorkbookCell.text('GST', style: 5),
      const _WorkbookCell.text('GST Status', style: 5),
      const _WorkbookCell.text('Final Total', style: 5),
      const _WorkbookCell.text('Payment Method', style: 5),
      const _WorkbookCell.text('Cash', style: 5),
      const _WorkbookCell.text('UPI', style: 5),
      const _WorkbookCell.text('Card', style: 5),
    ],
    for (final invoice in report.invoices)
      [
        _WorkbookCell.text(invoice.invoiceNumber),
        _dateOnlyCell(invoice.createdAt),
        _timeCell(invoice.createdAt),
        _dateTimeCell(
          invoice.paidAt.isEmpty ? invoice.createdAt : invoice.paidAt,
        ),
        const _WorkbookCell.text(''),
        _WorkbookCell.text(_itemsLabel(invoice)),
        _moneyCell(invoice.subtotal),
        _moneyCell(invoice.discountAmount),
        _moneyCell(invoice.totalTax),
        _WorkbookCell.text(invoice.gstEnabled ? 'ON' : 'OFF'),
        _moneyCell(invoice.grandTotal),
        _WorkbookCell.text(_paymentLabel(invoice)),
        _paymentAmountCell(invoice, 'cash'),
        _paymentAmountCell(invoice, 'upi'),
        _paymentAmountCell(invoice, 'card'),
      ],
  ];

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
<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Monthly Summary" sheetId="1" r:id="rId1"/><sheet name="Orders" sheetId="2" r:id="rId2"/></sheets>
</workbook>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/styles.xml',
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="5"><numFmt numFmtId="164" formatCode="₹#,##0.00"/><numFmt numFmtId="165" formatCode="dd-mm-yyyy hh:mm"/><numFmt numFmtId="166" formatCode="0.###"/><numFmt numFmtId="167" formatCode="dd-mm-yyyy"/><numFmt numFmtId="168" formatCode="hh:mm:ss"/></numFmts>
<fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="9"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="2" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="168" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet1.xml',
        _worksheetXml(summaryRows, const [28, 20, 20]),
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet2.xml',
        _worksheetXml(
          orderRows,
          const [24, 14, 12, 21, 12, 52, 14, 14, 14, 13, 16, 24, 14, 14, 14],
          autoFilter: true,
          freezeHeader: true,
        ),
      ),
    );

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

_WorkbookCell _moneyCell(String value) =>
    _WorkbookCell.number(_parseNumber(value, 'currency'), style: 1);

_WorkbookCell _dateCell(String value) {
  final date = DateTime.parse(value).toLocal();
  final serial =
      date.difference(DateTime(1899, 12, 30)).inMicroseconds /
      Duration.microsecondsPerDay;
  return _WorkbookCell.number(serial, style: 2);
}

_WorkbookCell _dateOnlyCell(String value) {
  final date = DateTime.parse(value).toLocal();
  final serial =
      date.difference(DateTime(1899, 12, 30)).inMicroseconds /
      Duration.microsecondsPerDay;
  return _WorkbookCell.number(serial.floorToDouble(), style: 6);
}

_WorkbookCell _timeCell(String value) {
  final date = DateTime.parse(value).toLocal();
  final seconds = (date.hour * 3600) + (date.minute * 60) + date.second;
  return _WorkbookCell.number(seconds / Duration.secondsPerDay, style: 7);
}

_WorkbookCell _dateTimeCell(String value) {
  if (value.isEmpty) return const _WorkbookCell.text('');
  return _dateCell(value);
}

String _itemsLabel(SalesInvoiceReport invoice) => invoice.items
    .map((item) {
      final unit = item.unit.isEmpty ? '' : ' ${item.unit}';
      return '${item.productName} × ${item.quantity}$unit';
    })
    .join('\n');

_WorkbookCell _paymentAmountCell(SalesInvoiceReport invoice, String method) {
  final payment = invoice.paymentMethods.where((item) => item.method == method);
  return payment.isEmpty
      ? const _WorkbookCell.number(0, style: 1)
      : _moneyCell(payment.first.amount);
}

double _parseNumber(String value, String field) {
  final number = double.tryParse(value);
  if (number == null || !number.isFinite) {
    throw FormatException('Invalid $field in report data.', value);
  }
  return number;
}

String _paymentLabel(SalesInvoiceReport invoice) => invoice.paymentMethods
    .map((payment) => '${_paymentMethodName(payment.method)} ${payment.amount}')
    .join(' + ');

String _paymentMethodName(String method) => switch (method) {
  'cash' => 'Cash',
  'upi' => 'UPI',
  'card' => 'Card',
  'split' => 'Split',
  _ => method,
};

String _worksheetXml(
  List<List<_WorkbookCell?>> rows,
  List<double> widths, {
  bool autoFilter = false,
  bool freezeHeader = false,
}) {
  final contents = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
  );
  if (freezeHeader) {
    contents.write(
      '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>',
    );
  }
  contents.write('<cols>');
  for (var index = 0; index < widths.length; index++) {
    final column = index + 1;
    contents.write(
      '<col min="$column" max="$column" width="${widths[index]}" customWidth="1"/>',
    );
  }
  contents.write('</cols><sheetData>');
  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    contents.write('<row r="${rowIndex + 1}">');
    final row = rows[rowIndex];
    for (var columnIndex = 0; columnIndex < row.length; columnIndex++) {
      final cell = row[columnIndex];
      if (cell == null || cell.value == '') continue;
      final reference = '${_columnName(columnIndex + 1)}${rowIndex + 1}';
      if (cell.value is String) {
        contents.write('<c r="$reference"');
        if (cell.style != 0) contents.write(' s="${cell.style}"');
        contents
          ..write(' t="inlineStr"><is><t xml:space="preserve">')
          ..write(_escapeXml(cell.value as String))
          ..write('</t></is></c>');
      } else {
        contents
          ..write('<c r="$reference" s="${cell.style}"><v>')
          ..write(cell.value)
          ..write('</v></c>');
      }
    }
    contents.write('</row>');
  }
  contents.write('</sheetData>');
  if (autoFilter && rows.isNotEmpty) {
    contents.write(
      '<autoFilter ref="A1:${_columnName(widths.length)}${rows.length}"/>',
    );
  }
  contents.write('</worksheet>');
  return contents.toString();
}

String _columnName(int column) {
  final letters = StringBuffer();
  var value = column;
  while (value > 0) {
    value -= 1;
    letters.writeCharCode(65 + value % 26);
    value ~/= 26;
  }
  return String.fromCharCodes(letters.toString().codeUnits.reversed);
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
