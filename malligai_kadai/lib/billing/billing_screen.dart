
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'billing_gateway.dart';
import 'receipt_preview_screen.dart';
import 'receipt_printer.dart';
import '../products/product_gateway.dart';

class BillingScreen extends StatefulWidget {
  const BillingScreen({
    super.key,
    required this.productGateway,
    required this.billingGateway,
    required this.receiptPrinterGateway,
  });

  final ProductGateway productGateway;
  final BillingGateway billingGateway;
  final ReceiptPrinterGateway receiptPrinterGateway;

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

BigInt? _parseQuantityInput(String value, String baseUnit, String inputUnit) {
  final trimmed = value.trim();
  if (!RegExp(r'^\d+(?:\.\d{0,3})?$').hasMatch(trimmed)) return null;
  final parts = trimmed.split('.');
  final inputMilli =
      BigInt.parse(parts[0]) * BigInt.from(1000) +
      BigInt.parse((parts.length > 1 ? parts[1] : '').padRight(3, '0'));
  if (baseUnit == inputUnit) return inputMilli;
  if (baseUnit == 'kg' && inputUnit == 'g') {
    if (inputMilli % BigInt.from(1000) != BigInt.zero) return null;
    return inputMilli ~/ BigInt.from(1000);
  }
  if (baseUnit == 'g' && inputUnit == 'kg') {
    return inputMilli * BigInt.from(1000);
  }
  return null;
}

String _displayQuantity(_CartLine line) {
  var quantityMilli = BigInt.from(line.quantityMilli);
  if (line.product.unit == 'kg' && line.selectedUnit == 'g') {
    quantityMilli *= BigInt.from(1000);
  } else if (line.product.unit == 'g' && line.selectedUnit == 'kg') {
    quantityMilli ~/= BigInt.from(1000);
  }
  final value =
      '${quantityMilli ~/ BigInt.from(1000)}.'
      '${(quantityMilli % BigInt.from(1000)).toString().padLeft(3, '0')}';
  return value.replaceFirst(RegExp(r'\.?0+$'), '');
}

List<String> _quantityUnits(ProductItem product) => switch (product.unit) {
  'kg' => const ['kg', 'g'],
  'g' => const ['g', 'kg'],
  _ => [product.unit],
};

class _CartLine {
  const _CartLine(
    this.product,
    this.quantityMilli,
    this.unitPrice, {
    this.quantityUnit,
  });

  final ProductItem product;
  final int quantityMilli;
  final String unitPrice;
  final String? quantityUnit;

  String get selectedUnit => quantityUnit ?? product.unit;

  _CartLine withQuantity(int value) =>
      _CartLine(product, value, unitPrice, quantityUnit: quantityUnit);

  _CartLine withQuantityUnit(String value) =>
      _CartLine(product, quantityMilli, unitPrice, quantityUnit: value);
}

class _QuantityEntry {
  const _QuantityEntry(this.unit, this.quantityMilli);

  final String unit;
  final int quantityMilli;
}

class _ProductQuantityDialog extends StatefulWidget {
  const _ProductQuantityDialog({required this.product});

  final ProductItem product;

  @override
  State<_ProductQuantityDialog> createState() => _ProductQuantityDialogState();
}

class _ProductQuantityDialogState extends State<_ProductQuantityDialog> {
  late String? _selectedUnit = widget.product.unit;
  late final TextEditingController _quantityController = TextEditingController(
    text: _selectedUnit == 'g' ? '100' : '1',
  );
  String? _error;

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  void _changeUnit(String? unit) {
    if (unit == null) return;
    setState(() {
      _selectedUnit = unit;
      _quantityController.text = unit == 'g' ? '100' : '1';
      _error = null;
    });
  }

  void _addToBill() {
    final unit = _selectedUnit;
    if (unit == null) {
      setState(() => _error = 'Choose a unit and enter a valid quantity.');
      return;
    }
    final parsed = _parseQuantityInput(
      _quantityController.text,
      widget.product.unit,
      unit,
    );
    if (parsed == null ||
        parsed <= BigInt.zero ||
        parsed > BigInt.from(999999999999)) {
      setState(() => _error = 'Choose a unit and enter a valid quantity.');
      return;
    }
    Navigator.pop(context, _QuantityEntry(unit, parsed.toInt()));
  }

  @override
  Widget build(BuildContext context) {
    final requiresUnit =
        widget.product.unit == 'kg' || widget.product.unit == 'g';
    return AlertDialog(
      title: Text('Enter ${widget.product.name} quantity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (requiresUnit) ...[
            DropdownButtonFormField<String>(
              key: Key('newQuantityUnit-${widget.product.id}'),
              initialValue: _selectedUnit,
              decoration: const InputDecoration(
                labelText: 'Choose unit',
                border: OutlineInputBorder(),
              ),
              items: _quantityUnits(widget.product)
                  .map(
                    (unit) => DropdownMenuItem(value: unit, child: Text(unit)),
                  )
                  .toList(growable: false),
              onChanged: _changeUnit,
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: Key('newQuantityInput-${widget.product.id}'),
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            controller: _quantityController,
            decoration: InputDecoration(
              labelText:
                  'Quantity${_selectedUnit == null ? '' : ' ($_selectedUnit)'}',
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: Key('confirmProductQuantity-${widget.product.id}'),
          onPressed: _addToBill,
          child: const Text('Add to bill'),
        ),
      ],
    );
  }
}

class _BillingScreenState extends State<BillingScreen> {
  final _searchController = TextEditingController();
  final _discountController = TextEditingController(text: '0.00');
  final _uuid = const Uuid();
  Timer? _searchDebounce;
  List<ProductItem> _results = [];
  final Map<String, _CartLine> _cart = {};
  final Set<String> _invalidQuantityIds = {};
  bool _isSearching = false;
  bool _isSaving = false;
  String? _searchError;
  String? _billingError;
  String? _pendingIdempotencyKey;
  int _searchGeneration = 0;
  GstSettings? _gstSettings;
  String _paymentMode = 'cash';
  final _splitAmounts = <String, TextEditingController>{
    'cash': TextEditingController(),
    'upi': TextEditingController(),
    'card': TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    _searchProducts();
    _loadGstSettings();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _discountController.dispose();
    for (final controller in _splitAmounts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadGstSettings() async {
    try {
      final settings = await widget.billingGateway.getGstSettings();
      if (mounted) {
        setState(() {
          _gstSettings = settings;
        });
      }
    } on BillingFailure catch (error) {
      if (mounted) setState(() => _billingError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _billingError = 'Could not load shop tax settings.');
      }
    }
  }

  Future<void> _searchProducts() async {
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      _searchError = null;
    });
    try {
      final products = await widget.productGateway.searchProducts(
        _searchController.text,
      );
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _results = products;
          _isSearching = false;
        });
      }
    } on ProductFailure catch (error) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchError = error.message;
          _isSearching = false;
        });
      }
    } catch (_) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchError = 'Could not search products. Please try again.';
          _isSearching = false;
        });
      }
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), _searchProducts);
  }

  BigInt? _tryPriceCents(String value) {
    final trimmed = value.trim();
    if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(trimmed)) return null;
    final parts = trimmed.split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100) +
        BigInt.parse((parts.length > 1 ? parts[1] : '').padRight(2, '0'));
  }

  BigInt _lineTotalCents(_CartLine line) {
    final unitPriceCents = _tryPriceCents(line.unitPrice);
    if (unitPriceCents == null) return BigInt.zero;
    return (unitPriceCents * BigInt.from(line.quantityMilli) +
            BigInt.from(500)) ~/
        BigInt.from(1000);
  }

  BigInt get _subtotalCents => _cart.values.fold(
    BigInt.zero,
    (sum, line) => sum + _lineTotalCents(line),
  );

  String _formatMoney(BigInt cents) =>
      '${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';

  BigInt get _discountCents =>
      _parseMoney(_discountController.text) < BigInt.zero
      ? BigInt.zero
      : _parseMoney(_discountController.text);

  BigInt get _amountAfterDiscountCents => _subtotalCents >= _discountCents
      ? _subtotalCents - _discountCents
      : BigInt.zero;

  BigInt get _gstCents {
    if (_gstSettings?.gstEnabled != true) return BigInt.zero;
    final rateHundredths = _parseMoney(_gstSettings!.gstRate);
    if (rateHundredths == BigInt.zero) return BigInt.zero;
    if (_gstSettings!.priceMode == 'inclusive') {
      final denominator = BigInt.from(10000) + rateHundredths;
      final taxable =
          (_amountAfterDiscountCents * BigInt.from(10000) +
              denominator ~/ BigInt.from(2)) ~/
          denominator;
      return _amountAfterDiscountCents - taxable;
    }
    return (_amountAfterDiscountCents * rateHundredths + BigInt.from(5000)) ~/
        BigInt.from(10000);
  }

  BigInt get _taxableCents => _gstSettings?.priceMode == 'inclusive'
      ? _amountAfterDiscountCents - _gstCents
      : _amountAfterDiscountCents;

  BigInt get _grandTotalCents => _gstSettings?.priceMode == 'inclusive'
      ? _amountAfterDiscountCents
      : _taxableCents + _gstCents;

  Widget _summaryRow(String label, BigInt cents, {bool bold = false}) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold)
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text(
            '₹${_formatMoney(cents)}',
            key: Key('summary-${label.toLowerCase().replaceAll(' ', '')}'),
            style: style,
          ),
        ],
      ),
    );
  }

  String _formatQuantity(int milli) {
    return '${milli ~/ 1000}.${(milli % 1000).toString().padLeft(3, '0')}';
  }

  Future<void> _requestProductQuantity(ProductItem product) async {
    final entry = await showDialog<_QuantityEntry>(
      context: context,
      builder: (_) => _ProductQuantityDialog(product: product),
    );
    if (entry == null || !mounted) return;
    final existing = _cart[product.id];
    setState(() {
      _cart[product.id] = _CartLine(
        product,
        (existing?.quantityMilli ?? 0) + entry.quantityMilli,
        existing?.unitPrice ?? product.sellingPrice,
        quantityUnit: entry.unit,
      );
      _pendingIdempotencyKey = null;
      _billingError = null;
    });
  }

  void _removeProduct(String productId) {
    setState(() {
      _cart.remove(productId);
      _invalidQuantityIds.remove(productId);
      _pendingIdempotencyKey = null;
      _billingError = null;
    });
  }

  Future<void> _saveInvoice() async {
    if (_cart.isEmpty || _isSaving) return;
    if (_invalidQuantityIds.isNotEmpty) {
      setState(
        () => _billingError = 'Enter a valid quantity using the selected unit.',
      );
      return;
    }
    if (_cart.values.any(
      (line) =>
          _tryPriceCents(line.unitPrice) == null ||
          _tryPriceCents(line.unitPrice)! <= BigInt.zero,
    )) {
      setState(
        () => _billingError =
            'Enter a positive product amount with up to 2 decimal places.',
      );
      return;
    }
    final discount = _parseMoney(_discountController.text);
    if (discount < BigInt.zero || discount > _subtotalCents) {
      setState(
        () => _billingError =
            'Discount must be a valid amount no greater than the subtotal.',
      );
      return;
    }
    List<InvoicePayment> payments;
    if (_paymentMode == 'split') {
      payments = [];
      for (final method in const ['cash', 'upi', 'card']) {
        final controller = _splitAmounts[method]!;
        if (controller.text.trim().isEmpty) continue;
        final cents = _parseMoney(controller.text);
        if (cents <= BigInt.zero) {
          setState(() => _billingError = 'Payment amounts must be positive.');
          return;
        }
        payments.add(
          InvoicePayment(method: method, amount: _formatMoney(cents)),
        );
      }
    } else {
      payments = [
        InvoicePayment(
          method: _paymentMode,
          amount: _formatMoney(_grandTotalCents),
        ),
      ];
    }
    if (payments.isEmpty ||
        payments.fold(
              BigInt.zero,
              (sum, payment) => sum + _parseMoney(payment.amount),
            ) !=
            _grandTotalCents) {
      setState(
        () => _billingError =
            'Payment total must equal ₹${_formatMoney(_grandTotalCents)}.',
      );
      return;
    }

    final idempotencyKey = _pendingIdempotencyKey ?? _uuid.v4();
    setState(() {
      _isSaving = true;
      _billingError = null;
      _pendingIdempotencyKey = idempotencyKey;
    });
    try {
      final invoice = await widget.billingGateway.createInvoice(
        idempotencyKey: idempotencyKey,
        items: _cart.values
            .map(
              (line) => InvoiceCartItem(
                productId: line.product.id,
                quantity: _formatQuantity(line.quantityMilli),
                unitPrice: line.unitPrice.trim(),
              ),
            )
            .toList(growable: false),
        saleStateCode: _gstSettings!.stateCode,
        discountAmount: _formatMoney(discount),
        gstAmount: '0.00',
        payments: payments,
      );
      if (!mounted) return;

      setState(() {
        _cart.clear();
        _pendingIdempotencyKey = null;
        _isSaving = false;
      });
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Invoice saved'),
          content: Text(
            '${invoice.invoiceNumber}\nTotal ₹${invoice.grandTotal}'
            '${invoice.replayed ? '\nThis is the saved result of a retry.' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'done'),
              child: const Text('Done'),
            ),
            TextButton(
              key: const Key('previewSavedInvoiceButton'),
              onPressed: () => Navigator.pop(context, 'preview'),
              child: const Text('Preview Invoice'),
            ),
            TextButton(
              key: const Key('printSavedInvoiceButton'),
              onPressed: () => Navigator.pop(context, 'print'),
              child: const Text('Print Invoice'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action == 'preview') {
        await showDialog<void>(
          context: context,
          builder: (_) => ReceiptPreviewScreen(
            invoice: invoice,
            printerGateway: widget.receiptPrinterGateway,
          ),
        );
      } else if (action == 'print') {
        try {
          final printed = await widget.receiptPrinterGateway.printReceipt(
            invoice,
            a4Invoice: false,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  printed
                      ? 'Invoice ${invoice.invoiceNumber} sent to the receipt printer.'
                      : 'Printing was cancelled.',
                ),
              ),
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
              const SnackBar(
                content: Text('Could not print the saved invoice.'),
              ),
            );
          }
        }
      }
    } on BillingFailure catch (error) {
      if (mounted) setState(() => _billingError = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _billingError =
              'Could not save the invoice. Retry without changing the cart.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  BigInt _parseMoney(String value) {
    if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(value.trim())) {
      return BigInt.from(-1);
    }
    final parts = value.trim().split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100) +
        BigInt.parse((parts.length > 1 ? parts[1] : '').padRight(2, '0'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Billing & Cart'),
        actions: [
          if (_cart.isNotEmpty)
            TextButton.icon(
              key: const Key('clearCartButton'),
              onPressed: _isSaving
                  ? null
                  : () => setState(() {
                      _cart.clear();
                      _pendingIdempotencyKey = null;
                      _billingError = null;
                    }),
              icon: const Icon(Icons.remove_shopping_cart_outlined),
              label: const Text('Clear cart'),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 850;
            final results = _productPanel();
            final cart = _cartPanel();
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: results),
                  const SizedBox(width: 20),
                  Expanded(flex: 6, child: cart),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: results),
                const SizedBox(height: 16),
                Expanded(child: cart),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _productPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('billingSearchField'),
          controller: _searchController,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            labelText: 'Search products',
            hintText: 'Name, SKU or barcode',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        if (_isSearching)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_searchError != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _searchError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _searchProducts,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          )
        else if (_results.isEmpty)
          const Expanded(child: Center(child: Text('No matching products.')))
        else
          Expanded(
            child: ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final product = _results[index];
                return Card(
                  child: ListTile(
                    title: Text(product.name),
                    subtitle: Text(
                      [
                        if (product.sku.isNotEmpty) product.sku,
                        product.unit,
                      ].join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '₹${product.sellingPrice}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        IconButton(
                          key: Key('addToCart-${product.id}'),
                          tooltip: 'Add ${product.name} to cart',
                          onPressed: () => _requestProductQuantity(product),
                          icon: const Icon(Icons.add_shopping_cart_rounded),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _cartPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Current bill',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                Text('${_cart.length} item(s)'),
              ],
            ),
            const Divider(height: 24),
            if (_cart.isEmpty)
              const Expanded(
                child: Center(child: Text('Search and add products to begin.')),
              )
            else
              Expanded(
                child: ListView(
                  children: _cart.values.map(_cartItem).toList(growable: false),
                ),
              ),
            if (_billingError != null) ...[
              const SizedBox(height: 8),
              Text(
                _billingError!,
                key: const Key('billingError'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            const Divider(height: 24),
            _summaryRow('Subtotal', _subtotalCents),
            TextField(
              key: const Key('discountAmountField'),
              controller: _discountController,
              enabled: !_isSaving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Discount amount',
                prefixText: '₹',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _pendingIdempotencyKey = null;
                _billingError = null;
              }),
            ),
            _summaryRow('Discount', _discountCents),
            _summaryRow('Amount before GST', _taxableCents),
            if (_gstSettings?.gstEnabled == true) ...[
              _summaryRow('GST', _gstCents),
            ],
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: const Key('paymentModeField'),
              initialValue: _paymentMode,
              decoration: const InputDecoration(
                labelText: 'Payment method',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('Cash')),
                DropdownMenuItem(value: 'upi', child: Text('UPI')),
                DropdownMenuItem(value: 'card', child: Text('Card')),
                DropdownMenuItem(value: 'split', child: Text('Split payment')),
              ],
              onChanged: _isSaving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _paymentMode = value;
                          _pendingIdempotencyKey = null;
                        });
                      }
                    },
            ),
            if (_paymentMode == 'split')
              for (final method in const ['cash', 'upi', 'card'])
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    key: Key('payment-$method'),
                    controller: _splitAmounts[method],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: '$method amount',
                      prefixText: '₹',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {
                      _pendingIdempotencyKey = null;
                    }),
                  ),
                ),
            const SizedBox(height: 8),
            _summaryRow('Final total', _grandTotalCents, bold: true),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('saveInvoiceButton'),
              onPressed: _cart.isNotEmpty && !_isSaving && _gstSettings != null
                  ? _saveInvoice
                  : null,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.receipt_long_outlined),
              label: Text(_isSaving ? 'Saving invoice…' : 'Save invoice'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cartItem(_CartLine line) {
    final product = line.product;
    final lineTotal = _formatMoney(_lineTotalCents(line));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  product.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: 130,
                child: TextFormField(
                  key: Key('amount-${product.id}'),
                  initialValue: line.unitPrice,
                  enabled: !_isSaving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount per ${product.unit}',
                    prefixText: '₹',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _cart[product.id] = _CartLine(
                        product,
                        line.quantityMilli,
                        value,
                        quantityUnit: line.quantityUnit,
                      );
                      _pendingIdempotencyKey = null;
                      _billingError = null;
                    });
                  },
                ),
              ),
              IconButton(
                key: Key('remove-${product.id}'),
                tooltip: 'Remove ${product.name}',
                onPressed: _isSaving ? null : () => _removeProduct(product.id),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Quantity'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: Key('quantityUnit-${product.id}'),
                value: line.selectedUnit,
                items: _quantityUnits(product)
                    .map(
                      (unit) =>
                          DropdownMenuItem(value: unit, child: Text(unit)),
                    )
                    .toList(growable: false),
                onChanged: _isSaving
                    ? null
                    : (unit) {
                        if (unit == null) return;
                        setState(() {
                          _cart[product.id] = line.withQuantityUnit(unit);
                          _invalidQuantityIds.remove(product.id);
                          _billingError = null;
                          _pendingIdempotencyKey = null;
                        });
                      },
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: TextFormField(
                  key: Key('quantityInput-${product.id}-${line.selectedUnit}'),
                  initialValue: _displayQuantity(line),
                  enabled: !_isSaving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: line.selectedUnit,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    final parsed = _parseQuantityInput(
                      value,
                      product.unit,
                      line.selectedUnit,
                    );
                    setState(() {
                      if (parsed == null ||
                          parsed <= BigInt.zero ||
                          parsed > BigInt.from(999999999999)) {
                        _invalidQuantityIds.add(product.id);
                        _billingError =
                            'Enter a valid quantity using the selected unit.';
                      } else {
                        _invalidQuantityIds.remove(product.id);
                        _cart[product.id] = line.withQuantity(parsed.toInt());
                        _billingError = null;
                      }
                      _pendingIdempotencyKey = null;
                    });
                  },
                ),
              ),
              const Spacer(),
              Text(
                '₹$lineTotal',
                key: Key('lineTotal-${product.id}'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
