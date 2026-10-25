import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing_gateway.dart';
import 'receipt_formatter.dart';

class InstalledReceiptPrinter {
  const InstalledReceiptPrinter({
    required this.name,
    required this.url,
    required this.isAvailable,
    required this.isDefault,
  });

  final String name;
  final String url;
  final bool isAvailable;
  final bool isDefault;
}

class ReceiptPrinterSettings {
  const ReceiptPrinterSettings({
    required this.printerName,
    required this.printerUrl,
    required this.paperWidthMm,
    this.printableWidthMm,
    this.a4Invoices = false,
  });

  static const defaultPaperWidthMm = 80;
  static const defaultPrintableWidthMm = 72.0;
  static const minimumPrintableWidthMm = 40.0;

  final String printerName;
  final String printerUrl;
  final int paperWidthMm;
  final double? printableWidthMm;
  final bool a4Invoices;

  double get targetPrintableWidthMm =>
      printableWidthMm ?? (paperWidthMm - 8).toDouble();
}

class ReceiptPrinterFailure implements Exception {
  const ReceiptPrinterFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ReceiptPrinterGateway {
  Future<List<InstalledReceiptPrinter>> listPrinters();
  Future<ReceiptPrinterSettings?> loadSettings();
  Future<void> saveSettings(ReceiptPrinterSettings settings);
  Future<Uint8List> buildPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool a4Invoice = false,
  });
  Future<bool> printReceipt(
    SavedInvoice invoice, {
    bool testMode = false,
    bool? a4Invoice,
    void Function(String notice)? onPrintNotice,
  });
}

class WindowsReceiptPrinterGateway implements ReceiptPrinterGateway {
  WindowsReceiptPrinterGateway({SharedPreferencesAsync? preferences})
    : _providedPreferences = preferences;

  static const _printerNameKey = 'receipt_printer_name';
  static const _printerUrlKey = 'receipt_printer_url';
  static const _paperWidthKey = 'receipt_paper_width_mm';
  static const _printableWidthKey = 'receipt_printable_width_mm';
  static const _a4InvoicesKey = 'receipt_a4_invoices';

  final SharedPreferencesAsync? _providedPreferences;
  late final SharedPreferencesAsync _preferences =
      _providedPreferences ?? SharedPreferencesAsync();

  @override
  Future<List<InstalledReceiptPrinter>> listPrinters() async {
    final capabilities = await Printing.info();
    if (!capabilities.canListPrinters) {
      throw const ReceiptPrinterFailure(
        'This Windows printing service cannot list installed printers.',
      );
    }
    try {
      final List<Printer> printers;
      try {
        printers = await Printing.listPrinters();
      } on PlatformException catch (error) {
        throw ReceiptPrinterFailure(
          'Windows could not list installed printers: ${error.message ?? error.code}. Install a printer and retry.',
        );
      }
      return printers
          .map(
            (printer) => InstalledReceiptPrinter(
              name: printer.name,
              url: printer.url,
              isAvailable: printer.isAvailable,
              isDefault: printer.isDefault,
            ),
          )
          .toList(growable: false);
    } on PlatformException catch (error) {
      throw ReceiptPrinterFailure(
        'Windows could not read its installed printers: ${error.message ?? error.code}.',
      );
    }
  }

  void _drawCenteredLogo(
    ui.Canvas canvas,
    ui.Image logo,
    double canvasWidth,
    double maxWidth,
    double maxHeight,
    double top,
  ) {
    final scale = math.min(maxWidth / logo.width, maxHeight / logo.height);
    final width = logo.width * scale;
    final height = logo.height * scale;
    final destination = ui.Rect.fromLTWH(
      (canvasWidth - width) / 2,
      top + (maxHeight - height) / 2,
      width,
      height,
    );
    canvas.drawImageRect(
      logo,
      ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      destination,
      ui.Paint(),
    );
  }

  @override
  Future<ReceiptPrinterSettings?> loadSettings() async {
    final printerName = await _preferences.getString(_printerNameKey);
    final printerUrl = await _preferences.getString(_printerUrlKey);
    final paperWidthMm = await _preferences.getInt(_paperWidthKey);
    if (printerName == null || printerUrl == null || paperWidthMm == null) {
      return null;
    }
    if (printerName.isEmpty ||
        printerUrl.isEmpty ||
        (paperWidthMm != 58 && paperWidthMm != 80)) {
      throw const ReceiptPrinterFailure(
        'Saved receipt printer settings are invalid. Choose the printer again.',
      );
    }
    final printableWidthMm =
        await _preferences.getDouble(_printableWidthKey) ??
        (paperWidthMm - 8).toDouble();
    if (!printableWidthMm.isFinite ||
        printableWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        printableWidthMm > paperWidthMm) {
      throw const ReceiptPrinterFailure(
        'Saved printable receipt width is invalid. Adjust it in receipt printer settings.',
      );
    }
    return ReceiptPrinterSettings(
      printerName: printerName,
      printerUrl: printerUrl,
      paperWidthMm: paperWidthMm,
      printableWidthMm: printableWidthMm,
      a4Invoices: await _preferences.getBool(_a4InvoicesKey) ?? false,
    );
  }

  @override
  Future<void> saveSettings(ReceiptPrinterSettings settings) async {
    if (settings.printerName.isEmpty ||
        settings.printerUrl.isEmpty ||
        (settings.paperWidthMm != 58 && settings.paperWidthMm != 80) ||
        !settings.targetPrintableWidthMm.isFinite ||
        settings.targetPrintableWidthMm <
            ReceiptPrinterSettings.minimumPrintableWidthMm ||
        settings.targetPrintableWidthMm > settings.paperWidthMm) {
      throw const ReceiptPrinterFailure(
        'Choose a printer, roll size, and printable width within the roll.',
      );
    }
    await _preferences.setString(_printerNameKey, settings.printerName);
    await _preferences.setString(_printerUrlKey, settings.printerUrl);
    await _preferences.setInt(_paperWidthKey, settings.paperWidthMm);
    await _preferences.setDouble(
      _printableWidthKey,
      settings.targetPrintableWidthMm,
    );
    await _preferences.setBool(_a4InvoicesKey, settings.a4Invoices);
  }

  @override
  Future<Uint8List> buildPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool a4Invoice = false,
  }) async {
    if (a4Invoice) return _buildA4Pdf(invoice, testMode: testMode);
    final receipt = await _buildReceiptPdf(
      invoice,
      paperWidthMm: paperWidthMm,
      printableWidthMm: printableWidthMm,
      testMode: testMode,
    );
    return receipt.bytes;
  }

  Future<({Uint8List bytes, PdfPageFormat format})> _buildReceiptPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    required bool testMode,
  }) async {
    final contentWidthMm =
        printableWidthMm ??
        math.min(
          ReceiptPrinterSettings.defaultPrintableWidthMm,
          (paperWidthMm - 8).toDouble(),
        );
    if (!contentWidthMm.isFinite ||
        contentWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        contentWidthMm > paperWidthMm) {
      throw ArgumentError.value(printableWidthMm, 'printableWidthMm');
    }
    final lines = ReceiptFormatter.format(
      invoice,
      paperWidthMm: paperWidthMm,
      printableWidthMm: contentWidthMm,
      testMode: testMode,
    );
    final sideMarginMm = (paperWidthMm - contentWidthMm) / 2;
    final format = PdfPageFormat(
      paperWidthMm * PdfPageFormat.mm,
      1000 * PdfPageFormat.mm,
      marginLeft: sideMarginMm * PdfPageFormat.mm,
      marginRight: sideMarginMm * PdfPageFormat.mm,
      marginTop: 3 * PdfPageFormat.mm,
      marginBottom: 3 * PdfPageFormat.mm,
    );
    final document = pw.Document();
    const renderScale = 3.0;
    final titleBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Arial',
              fontSize: contentWidthMm * 0.2375 * renderScale,
              height: 1.05,
              fontWeight: ui.FontWeight.bold,
              textAlign: ui.TextAlign.center,
              textDirection: ui.TextDirection.ltr,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: const ui.Color(0xFF000000),
              fontWeight: ui.FontWeight.bold,
            ),
          )
          ..addText('${lines.first.trim()}\n');
    final titleParagraph = titleBuilder.build()
      ..layout(
        ui.ParagraphConstraints(width: format.availableWidth * renderScale),
      );
    final paragraphBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Consolas',
              fontSize: 7.8 * renderScale,
              height: 1.25,
              textDirection: ui.TextDirection.ltr,
            ),
          )
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)))
          ..addText(lines.skip(1).join('\n'));
    final paragraph = paragraphBuilder.build()
      ..layout(
        ui.ParagraphConstraints(width: format.availableWidth * renderScale),
      );
    final logoData = await rootBundle.load(
      'assets/thanigai_stores_receipt_logo_transparent.png',
    );
    final logoCodec = await ui.instantiateImageCodec(
      logoData.buffer.asUint8List(),
    );
    final logoFrame = await logoCodec.getNextFrame();
    final logo = logoFrame.image;
    final logoMaxWidth = math.min(
      (paperWidthMm - 12) * PdfPageFormat.mm * renderScale,
      paperWidthMm * 0.4 * PdfPageFormat.mm * renderScale,
    );
    const logoMaxHeight = 24 * PdfPageFormat.mm * renderScale;
    const logoGap = 1 * PdfPageFormat.mm * renderScale;
    const titleGap = 2 * PdfPageFormat.mm * renderScale;
    final titleTop = logoMaxHeight + logoGap;
    final bodyTop = titleTop + titleParagraph.height + titleGap;
    final contentHeight = (bodyTop + paragraph.height) / renderScale;
    final pageFormat = format.copyWith(
      height: contentHeight + format.marginTop + format.marginBottom,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    _drawCenteredLogo(
      canvas,
      logo,
      format.availableWidth * renderScale,
      logoMaxWidth,
      logoMaxHeight,
      0,
    );
    canvas
      ..drawParagraph(titleParagraph, ui.Offset(0, titleTop))
      ..drawParagraph(paragraph, ui.Offset(0, bodyTop));
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (format.availableWidth * renderScale).ceil(),
      (bodyTop + paragraph.height).ceil(),
    );
    logo.dispose();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (png == null) {
      throw const ReceiptPrinterFailure(
        'The receipt preview could not be rendered on this Windows PC.',
      );
    }
    final receiptImage = pw.MemoryImage(png.buffer.asUint8List());
    document.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.fromLTRB(
          sideMarginMm * PdfPageFormat.mm,
          3 * PdfPageFormat.mm,
          sideMarginMm * PdfPageFormat.mm,
          3 * PdfPageFormat.mm,
        ),
        build: (_) => pw.SizedBox(
          width: pageFormat.availableWidth,
          child: pw.Image(
            receiptImage,
            width: pageFormat.availableWidth,
            height: contentHeight,
          ),
        ),
      ),
    );
    return (bytes: await document.save(), format: pageFormat);
  }

  Future<Uint8List> _buildA4Pdf(
    SavedInvoice invoice, {
    required bool testMode,
  }) async {
    final document = pw.Document();
    final logoData = await rootBundle.load(
      'assets/thanigai_stores_receipt_logo.png',
    );
    final logoCodec = await ui.instantiateImageCodec(
      logoData.buffer.asUint8List(),
    );
    final logoFrame = await logoCodec.getNextFrame();
    final logo = logoFrame.image;
    final a4Lines = ReceiptFormatter.formatA4(
      invoice,
      testMode: testMode,
      includeFooter: false,
    );
    final title = a4Lines.first.trim();
    final bodyLines = a4Lines.skip(1).toList(growable: false);
    const linesPerPage = 40;
    const renderScale = 3.0;
    final format = PdfPageFormat.a4;
    const pageMargin = 32.0;
    final receiptWidth = format.width - pageMargin * 2;
    final canvasWidth = (receiptWidth * renderScale).ceil();
    final footerLines = ReceiptFormatter.formatA4Footer(
      invoice,
      testMode: testMode,
    );
    final footerBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontFamily: 'Consolas',
        fontSize: 11 * renderScale,
        height: 1.25,
        textAlign: ui.TextAlign.left,
        textDirection: ui.TextDirection.ltr,
      ),
    )..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)));
    footerBuilder.addText(footerLines.join('\n'));
    final footerParagraph = footerBuilder.build()
      ..layout(ui.ParagraphConstraints(width: canvasWidth.toDouble()));
    final footerRecorder = ui.PictureRecorder();
    ui.Canvas(footerRecorder).drawParagraph(footerParagraph, ui.Offset.zero);
    final footerPicture = footerRecorder.endRecording();
    final footerBitmap = await footerPicture.toImage(
      canvasWidth,
      footerParagraph.height.ceil(),
    );
    final footerData = await footerBitmap.toByteData(
      format: ui.ImageByteFormat.png,
    );
    footerBitmap.dispose();
    footerPicture.dispose();
    if (footerData == null) {
      logo.dispose();
      throw const ReceiptPrinterFailure(
        'The A4 invoice footer could not be rendered on this Windows PC.',
      );
    }
    final footerImage = pw.MemoryImage(footerData.buffer.asUint8List());

    final titleBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Consolas',
              fontSize: 16 * renderScale,
              height: 1.1,
              textAlign: ui.TextAlign.center,
              textDirection: ui.TextDirection.ltr,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: const ui.Color(0xFF000000),
              fontWeight: ui.FontWeight.bold,
            ),
          )
          ..addText('$title\n');
    final titleParagraph = titleBuilder.build()
      ..layout(ui.ParagraphConstraints(width: canvasWidth.toDouble()));

    for (var start = 0; start < bodyLines.length; start += linesPerPage) {
      final isFirstPage = start == 0;
      final pageLines = bodyLines.skip(start).take(linesPerPage).toList();
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(
          fontFamily: 'Consolas',
          fontSize: 11 * renderScale,
          height: 1.25,
          textDirection: ui.TextDirection.ltr,
        ),
      )..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)));
      for (final line in pageLines) {
        final isTotal = line.trimLeft().startsWith('TOTAL');
        builder.pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFF000000),
            fontWeight: isTotal ? ui.FontWeight.bold : ui.FontWeight.normal,
          ),
        );
        builder.addText('$line\n');
        builder.pop();
      }
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: canvasWidth.toDouble()));
      const logoMaxWidth = 32 * PdfPageFormat.mm * renderScale;
      const logoMaxHeight = 28 * PdfPageFormat.mm * renderScale;
      const logoGap = 1 * PdfPageFormat.mm * renderScale;
      const titleGap = 1.5 * PdfPageFormat.mm * renderScale;
      final titleTop = logoMaxHeight + logoGap;
      final bodyTop = isFirstPage
          ? titleTop + titleParagraph.height + titleGap
          : 0.0;
      final paragraphHeight = bodyTop + paragraph.height;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      if (isFirstPage) {
        _drawCenteredLogo(
          canvas,
          logo,
          canvasWidth.toDouble(),
          logoMaxWidth,
          logoMaxHeight,
          0,
        );
        canvas.drawParagraph(titleParagraph, ui.Offset(0, titleTop));
      }
      canvas.drawParagraph(paragraph, ui.Offset(0, bodyTop));
      final picture = recorder.endRecording();
      final image = await picture.toImage(canvasWidth, paragraphHeight.ceil());
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      if (png == null) {
        throw const ReceiptPrinterFailure(
          'The A4 invoice could not be rendered on this Windows PC.',
        );
      }
      final pageImage = pw.MemoryImage(png.buffer.asUint8List());
      final isLastPage = start + linesPerPage >= bodyLines.length;
      document.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(pageMargin),
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Center(
                child: pw.Image(
                  pageImage,
                  width: receiptWidth,
                  height: paragraphHeight / renderScale,
                ),
              ),
              pw.Spacer(),
              if (isLastPage)
                pw.Center(
                  child: pw.Image(
                    footerImage,
                    width: receiptWidth,
                    height: footerParagraph.height / renderScale,
                  ),
                ),
            ],
          ),
        ),
      );
    }
    logo.dispose();
    return document.save();
  }

  @override
  Future<bool> printReceipt(
    SavedInvoice invoice, {
    bool testMode = false,
    bool? a4Invoice,
    void Function(String notice)? onPrintNotice,
  }) async {
    final settings = await loadSettings();
    final capabilities = await Printing.info();
    if (!capabilities.canPrint || !capabilities.directPrint) {
      throw const ReceiptPrinterFailure(
        'Direct Windows printing is unavailable. Check the Windows printing service.',
      );
    }

    final printers = await Printing.listPrinters();
    Printer? selected;
    for (final printer in printers) {
      if (settings != null && printer.url == settings.printerUrl) {
        selected = printer;
        break;
      }
      if (printer.isDefault) {
        selected = printer;
      }
    }
    if (selected == null) {
      throw const ReceiptPrinterFailure(
        'Windows has no default printer selected. Install a printer and set it as the Windows default, then retry.',
      );
    }
    if (!selected.isAvailable) {
      throw ReceiptPrinterFailure(
        '${selected.name} is unavailable or offline. Check power, connection, paper, and the Windows printer queue.',
      );
    }

    final paperWidthMm =
        settings?.paperWidthMm ?? ReceiptPrinterSettings.defaultPaperWidthMm;
    final printableWidthMm =
        settings?.targetPrintableWidthMm ??
        ReceiptPrinterSettings.defaultPrintableWidthMm;
    try {
      final receipt = await _buildReceiptPdf(
        invoice,
        paperWidthMm: paperWidthMm,
        printableWidthMm: printableWidthMm,
        testMode: testMode,
      );
      final completed = await Printing.directPrintPdf(
        printer: selected,
        name: testMode ? 'Thanigai Stores Printer Test' : invoice.invoiceNumber,
        format: receipt.format,
        dynamicLayout: false,
        usePrinterSettings: false,
        onLayout: (_) async => receipt.bytes,
      );
      return completed;
    } on PlatformException catch (error) {
      throw ReceiptPrinterFailure(
        'Windows could not print to ${selected.name}. Check that the printer is online, has paper, and that its driver supports the selected roll width. ${error.message ?? error.code}',
      );
    } catch (error) {
      throw ReceiptPrinterFailure(
        'The print job for ${selected.name} failed. Check that it is online, has paper, and that its Windows driver supports the selected roll width. $error',
      );
    }
  }
}
