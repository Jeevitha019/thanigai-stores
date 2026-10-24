import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'billing_gateway.dart';
import 'receipt_printer.dart';

class ReceiptPreviewScreen extends StatefulWidget {
  const ReceiptPreviewScreen({
    super.key,
    required this.invoice,
    required this.printerGateway,
  });

  final SavedInvoice invoice;
  final ReceiptPrinterGateway printerGateway;

  @override
  State<ReceiptPreviewScreen> createState() => _ReceiptPreviewScreenState();
}

class _ReceiptPreviewScreenState extends State<ReceiptPreviewScreen> {
  late Future<ReceiptPrinterSettings?> _printerSettings = widget.printerGateway
      .loadSettings();

  PdfPageFormat _receiptFormat(int paperWidthMm) =>
      PdfPageFormat(paperWidthMm * PdfPageFormat.mm, 1000 * PdfPageFormat.mm);

  Future<void> _print() async {
    String? printNotice;
    try {
      final completed = await widget.printerGateway.printReceipt(
        widget.invoice,
        a4Invoice: false,
        onPrintNotice: (notice) => printNotice = notice,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            completed
                ? 'Receipt sent to the Windows printer.${printNotice == null ? '' : ' $printNotice'}'
                : 'Print was cancelled. The saved invoice was not changed.',
          ),
        ),
      );
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not print this receipt.')),
        );
      }
    }
  }

  Future<void> _savePdf(int paperWidthMm, double printableWidthMm) async {
    try {
      const typeGroup = XTypeGroup(label: 'PDF', extensions: ['pdf']);
      final location = await getSaveLocation(
        suggestedName: '${widget.invoice.invoiceNumber}.pdf',
        acceptedTypeGroups: [typeGroup],
      );
      if (location == null) return;
      final bytes = await widget.printerGateway.buildPdf(
        widget.invoice,
        paperWidthMm: paperWidthMm,
        printableWidthMm: printableWidthMm,
      );
      await XFile.fromData(
        bytes,
        mimeType: 'application/pdf',
        name: '${widget.invoice.invoiceNumber}.pdf',
      ).saveTo(location.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invoice saved to ${location.path}')),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the invoice PDF.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('receiptPreviewDialog'),
      backgroundColor: const Color(0xFFF1EEE8),
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: math.min(540, MediaQuery.sizeOf(context).width - 40),
        height: MediaQuery.sizeOf(context).height * 0.92,
        child: FutureBuilder<ReceiptPrinterSettings?>(
          future: _printerSettings,
          builder: (context, snapshot) {
            final paperWidthMm =
                snapshot.data?.paperWidthMm ??
                ReceiptPrinterSettings.defaultPaperWidthMm;
            final printableWidthMm =
                snapshot.data?.targetPrintableWidthMm ??
                ReceiptPrinterSettings.defaultPrintableWidthMm;
            final loading = snapshot.connectionState == ConnectionState.waiting;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        key: const Key('saveInvoicePdfButton'),
                        tooltip: 'Save receipt PDF',
                        onPressed: snapshot.hasError || loading
                            ? null
                            : () => _savePdf(paperWidthMm, printableWidthMm),
                        icon: const Icon(Icons.download_outlined),
                      ),
                      OutlinedButton(
                        key: const Key('printReceiptButton'),
                        onPressed: snapshot.hasError || loading ? null : _print,
                        child: const Text('Print bill'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const Key('closeReceiptPreviewButton'),
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: snapshot.hasError
                      ? _PrinterSettingsError(
                          onRetry: () => setState(
                            () => _printerSettings = widget.printerGateway
                                .loadSettings(),
                          ),
                        )
                      : loading
                      ? const Center(child: CircularProgressIndicator())
                      : PdfPreview(
                          key: const Key('receiptPdfPreview'),
                          build: (_) => widget.printerGateway.buildPdf(
                            widget.invoice,
                            paperWidthMm: paperWidthMm,
                            printableWidthMm: printableWidthMm,
                          ),
                          initialPageFormat: _receiptFormat(paperWidthMm),
                          pageFormats: {
                            '$paperWidthMm mm roll / '
                                    '${printableWidthMm.toStringAsFixed(1)} mm target':
                                _receiptFormat(paperWidthMm),
                          },
                          maxPageWidth: 320,
                          previewPageMargin: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          scrollViewDecoration: const BoxDecoration(
                            color: Color(0xFFF1EEE8),
                          ),
                          pdfPreviewPageDecoration: const BoxDecoration(
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x26000000),
                                offset: Offset(0, 2),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          canChangePageFormat: false,
                          canChangeOrientation: false,
                          canDebug: false,
                          allowPrinting: false,
                          allowSharing: false,
                          pdfFileName: '${widget.invoice.invoiceNumber}.pdf',
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PrinterSettingsError extends StatelessWidget {
  const _PrinterSettingsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Could not load the configured receipt width.',
            textAlign: TextAlign.center,
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}
