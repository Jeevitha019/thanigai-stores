import 'package:flutter/material.dart';

import 'billing_gateway.dart';

class GstSettingsScreen extends StatefulWidget {
  const GstSettingsScreen({super.key, required this.gateway});

  final BillingGateway gateway;

  @override
  State<GstSettingsScreen> createState() => _GstSettingsScreenState();
}

class _GstSettingsScreenState extends State<GstSettingsScreen> {
  final _stateController = TextEditingController();
  final _businessNameController = TextEditingController();
  final _businessAddressController = TextEditingController();
  final _businessPhoneController = TextEditingController();
  final _gstinController = TextEditingController();
  final _gstRateController = TextEditingController();
  bool _enabled = false;
  String _priceMode = 'exclusive';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stateController.dispose();
    _businessNameController.dispose();
    _businessAddressController.dispose();
    _businessPhoneController.dispose();
    _gstinController.dispose();
    _gstRateController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.gateway.getGstSettings();
      if (!mounted) return;
      setState(() {
        _enabled = settings.gstEnabled;
        _gstRateController.text = settings.gstRate;
        _priceMode = settings.priceMode;
        _stateController.text = settings.stateCode == '00'
            ? ''
            : settings.stateCode;
        _businessNameController.text = settings.businessName;
        _businessAddressController.text = settings.businessAddress;
        _businessPhoneController.text = settings.businessPhone;
        _gstinController.text = settings.gstin;
        _loading = false;
      });
    } on BillingFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load GST settings.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final stateCode = _stateController.text.trim();
    final businessName = _businessNameController.text.trim();
    final gstin = _gstinController.text.trim().toUpperCase();
    final gstRate = _gstRateController.text.trim();
    if (businessName.isEmpty) {
      setState(() => _error = 'Enter the registered business name.');
      return;
    }
    if (gstin.isNotEmpty &&
        !RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$')
            .hasMatch(gstin)) {
      setState(() => _error = 'Enter a valid 15-character GSTIN.');
      return;
    }
    if (!RegExp(r'^\d{2}$').hasMatch(stateCode)) {
      setState(() => _error = 'Enter the shop state code as two digits.');
      return;
    }
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(gstRate) ||
        (double.tryParse(gstRate) ?? 101) > 100) {
      setState(() => _error = 'GST rate must be between 0 and 100 percent.');
      return;
    }
    if (_enabled && stateCode == '00') {
      setState(() => _error = 'Enter the shop state code before enabling GST.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.gateway.updateGstSettings(
        gstEnabled: _enabled,
        gstRate: gstRate,
        priceMode: _priceMode,
        stateCode: stateCode,
        businessName: businessName,
        businessAddress: _businessAddressController.text.trim(),
        businessPhone: _businessPhoneController.text.trim(),
        gstin: gstin,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('GST settings saved.')));
      }
    } on BillingFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save GST settings.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Shop and tax settings',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('businessNameField'),
                            controller: _businessNameController,
                            maxLength: 160,
                            decoration: const InputDecoration(
                              labelText: 'Business name',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('businessAddressField'),
                            controller: _businessAddressController,
                            maxLength: 1000,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Business address',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('businessPhoneField'),
                            controller: _businessPhoneController,
                            maxLength: 64,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Phone number (optional)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('businessGstinField'),
                            controller: _gstinController,
                            maxLength: 15,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'GSTIN (optional)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            key: const Key('gstEnabledSwitch'),
                            title: const Text('Enable GST'),
                            subtitle: const Text(
                              'When off, the bill includes no GST.',
                            ),
                            value: _enabled,
                            onChanged: _saving
                                ? null
                                : (value) => setState(() => _enabled = value),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('settingsGstRateField'),
                            controller: _gstRateController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'GST Rate (%)',
                              helperText:
                                  'Automatically applied to new bills when GST is enabled.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            key: const Key('gstPriceMode'),
                            initialValue: _priceMode,
                            decoration: const InputDecoration(
                              labelText: 'Product price mode',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'exclusive',
                                child: Text('GST-exclusive'),
                              ),
                              DropdownMenuItem(
                                value: 'inclusive',
                                child: Text('GST-inclusive'),
                              ),
                            ],
                            onChanged: _saving
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _priceMode = value);
                                    }
                                  },
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('shopStateCodeField'),
                            controller: _stateController,
                            keyboardType: TextInputType.number,
                            maxLength: 2,
                            decoration: const InputDecoration(
                              labelText: 'Shop state code',
                              helperText: 'Used to choose CGST/SGST or IGST for a sale.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            key: const Key('saveGstSettingsButton'),
                            onPressed: _saving ? null : _save,
                            child: Text(
                              _saving ? 'Saving…' : 'Save GST settings',
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
