import 'package:flutter/material.dart';

import '../products/product_gateway.dart';

class StockManagementScreen extends StatefulWidget {
  const StockManagementScreen({
    super.key,
    required this.gateway,
    required this.canManage,
  });

  final StockGateway gateway;
  final bool canManage;

  @override
  State<StockManagementScreen> createState() => _StockManagementScreenState();
}

class _StockManagementScreenState extends State<StockManagementScreen> {
  List<StockProduct> _products = const [];
  final Map<String, TextEditingController> _openingQuantities = {};
  final Map<String, TextEditingController> _purchasePrices = {};
  bool _isLoading = true;
  String? _error;
  String? _savingProductId;

  @override
  void initState() {
    super.initState();
    _loadStocks();
  }

  @override
  void dispose() {
    for (final controller in _openingQuantities.values) {
      controller.dispose();
    }
    for (final controller in _purchasePrices.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStocks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final products = await widget.gateway.loadStocks();
      if (!mounted) return;
      for (final product in products) {
        _openingQuantities
                .putIfAbsent(
                  product.productId,
                  () => TextEditingController(text: product.openingQuantity),
                )
                .text =
            product.openingQuantity;
        _purchasePrices
                .putIfAbsent(
                  product.productId,
                  () =>
                      TextEditingController(text: product.openingPurchasePrice),
                )
                .text =
            product.openingPurchasePrice;
      }
      setState(() {
        _products = products;
        _isLoading = false;
      });
    } on ProductFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _isLoading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not load stock details: $error';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveOpeningStock(StockProduct product) async {
    final quantity = _openingQuantities[product.productId]!.text.trim();
    final price = _purchasePrices[product.productId]!.text.trim();
    if (_decimalError(quantity, scale: 3, allowZero: true) != null ||
        _decimalError(price, scale: 2, allowZero: true) != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid quantity and purchase price.'),
        ),
      );
      return;
    }
    setState(() => _savingProductId = product.productId);
    try {
      await widget.gateway.updateOpeningStock(
        product.productId,
        quantity,
        price,
      );
      await _loadStocks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${product.name} old stock saved.')),
        );
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save old stock: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingProductId = null);
    }
  }

  Future<void> _recordPurchase(StockProduct product) async {
    final purchase = await showDialog<_PurchaseDraft>(
      context: context,
      builder: (_) => const _NewPurchaseDialog(),
    );
    if (purchase == null || !mounted) return;
    setState(() => _savingProductId = product.productId);
    try {
      await widget.gateway.receiveStockPurchase(
        product.productId,
        purchase.quantity,
        purchase.purchasePrice,
        purchase.purchaseDate,
      );
      await _loadStocks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${product.name} purchase recorded.')),
        );
      }
    } on ProductFailure catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record the purchase: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingProductId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stocks'),
          actions: [
            IconButton(
              key: const Key('refreshStocksButton'),
              tooltip: 'Refresh stock',
              onPressed: _isLoading ? null : _loadStocks,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Old Stock'),
              Tab(text: 'New Stock'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _loadStocks,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              )
            : TabBarView(children: [_buildOldStock(), _buildNewStock()]),
      ),
    );
  }

  Widget _buildOldStock() {
    if (_products.isEmpty) {
      return const Center(child: Text('No products are available.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _products.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final product = _products[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Old stock remaining: ${product.openingRemainingQuantity}   •   Available stock: ${product.totalQuantity}',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 210,
                      child: TextField(
                        key: Key('openingQuantity_${product.productId}'),
                        controller: _openingQuantities[product.productId],
                        enabled:
                            widget.canManage &&
                            _savingProductId != product.productId,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Old quantity',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 210,
                      child: TextField(
                        key: Key('openingPurchasePrice_${product.productId}'),
                        controller: _purchasePrices[product.productId],
                        enabled:
                            widget.canManage &&
                            _savingProductId != product.productId,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Purchase price (₹)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (widget.canManage)
                      FilledButton(
                        key: Key('saveOpeningStock_${product.productId}'),
                        onPressed: _savingProductId == product.productId
                            ? null
                            : () => _saveOpeningStock(product),
                        child: _savingProductId == product.productId
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Save old stock'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNewStock() {
    if (_products.isEmpty) {
      return const Center(child: Text('No products are available.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _products.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final product = _products[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        product.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (widget.canManage)
                      FilledButton.icon(
                        key: Key('recordPurchase_${product.productId}'),
                        onPressed: _savingProductId == product.productId
                            ? null
                            : () => _recordPurchase(product),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Record purchase'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Available stock: ${product.totalQuantity}'),
                const Divider(height: 24),
                if (product.purchases.isEmpty)
                  const Text('No new purchases recorded.')
                else
                  for (final batch in product.purchases)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${batch.purchaseDate}  •  ${batch.quantity}  •  ₹${batch.purchasePrice}',
                            ),
                          ),
                          Text(
                            'Remaining ${batch.remainingQuantity}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PurchaseDraft {
  const _PurchaseDraft({
    required this.quantity,
    required this.purchasePrice,
    required this.purchaseDate,
  });

  final String quantity;
  final String purchasePrice;
  final String purchaseDate;
}

class _NewPurchaseDialog extends StatefulWidget {
  const _NewPurchaseDialog();
  @override
  State<_NewPurchaseDialog> createState() => _NewPurchaseDialogState();
}

class _NewPurchaseDialogState extends State<_NewPurchaseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _quantityController = TextEditingController();
  final _priceController = TextEditingController();
  DateTime _purchaseDate = DateTime.now();

  @override
  void dispose() {
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record new stock'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('newStockQuantityField'),
                controller: _quantityController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Quantity',
                  border: const OutlineInputBorder(),
                ),
                validator: (value) =>
                    _decimalError(value ?? '', scale: 3, allowZero: false),
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('newStockPurchasePriceField'),
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Purchase price (₹)',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    _decimalError(value ?? '', scale: 2, allowZero: true),
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Purchase date'),
                subtitle: Text(_formatDate(_purchaseDate)),
                trailing: const Icon(Icons.calendar_month_outlined),
                onTap: _chooseDate,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('saveNewPurchaseButton'),
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              _PurchaseDraft(
                quantity: _quantityController.text.trim(),
                purchasePrice: _priceController.text.trim(),
                purchaseDate: _formatDate(_purchaseDate),
              ),
            );
          },
          child: const Text('Save purchase'),
        ),
      ],
    );
  }

  Future<void> _chooseDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _purchaseDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (selected != null) setState(() => _purchaseDate = selected);
  }
}

String? _decimalError(
  String value, {
  required int scale,
  required bool allowZero,
}) {
  final normalized = value.trim();
  if (!RegExp(r'^\d+(?:\.\d{0,' + scale.toString() + r'})?$')
      .hasMatch(normalized)) {
    return 'Enter a valid number.';
  }
  final parsed = double.tryParse(normalized);
  if (parsed == null || parsed < 0 || (!allowZero && parsed == 0)) {
    return allowZero
        ? 'Enter a non-negative number.'
        : 'Enter a value above zero.';
  }
  return null;
}

String _formatDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
