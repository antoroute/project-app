import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/models/account_device.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_message_app/core/services/account_device_trust_service.dart';
import 'package:provider/provider.dart';

class AccountDevicesScreen extends StatefulWidget {
  const AccountDevicesScreen({super.key});

  @override
  State<AccountDevicesScreen> createState() => _AccountDevicesScreenState();
}

class _AccountDevicesScreenState extends State<AccountDevicesScreen> {
  List<AccountDevice> _devices = const <AccountDevice>[];
  bool _loading = true;
  String? _error;
  String? _decidingDeviceId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await context.read<AuthProvider>().fetchAccountDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (_) {
      if (mounted) setState(() => _error = 'Liste indisponible. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmDecision(
    AccountDevice device,
    DeviceApprovalDecision decision,
  ) async {
    final approve = decision == DeviceApprovalDecision.approve;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              approve ? 'Autoriser cet appareil ?' : 'Refuser cet appareil ?',
            ),
            content: Text(
              '${device.deviceName} · ${device.platform}\n\n'
              'Empreinte : ${device.fingerprint}\n\n'
              '${approve ? 'Il pourra recevoir uniquement les futurs messages.' : 'Son identité sera révoquée et ne pourra pas être réinscrite silencieusement.'}',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(approve ? 'Autoriser' : 'Refuser'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _decidingDeviceId = device.deviceId);
    try {
      await context.read<AuthProvider>().decidePendingDevice(
        target: device,
        decision: decision,
      );
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('La décision n’a pas pu être appliquée.'),
          ),
        );
        await _load();
      }
    } finally {
      if (mounted) setState(() => _decidingDeviceId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentDeviceId = context.watch<AuthProvider>().currentDeviceId;
    return Scaffold(
      appBar: AppBar(title: const Text('Appareils du compte')),
      body: RefreshIndicator(
        onRefresh: _load,
        child:
            _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    Text(_error!, textAlign: TextAlign.center),
                  ],
                )
                : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(12),
                  itemCount: _devices.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    final current = device.deviceId == currentDeviceId;
                    final deciding = _decidingDeviceId == device.deviceId;
                    return ListTile(
                      leading: Icon(_platformIcon(device.platform)),
                      title: Text(
                        '${device.deviceName}${current ? ' (cet appareil)' : ''}',
                      ),
                      subtitle: Text(
                        '${_statusLabel(device.status)} · ${device.platform}\n'
                        'Empreinte : ${device.fingerprint}',
                      ),
                      isThreeLine: true,
                      trailing:
                          device.status == AccountDeviceStatus.pending
                              ? deciding
                                  ? const SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : Wrap(
                                    children: <Widget>[
                                      IconButton(
                                        onPressed:
                                            () => _confirmDecision(
                                              device,
                                              DeviceApprovalDecision.reject,
                                            ),
                                        icon: const Icon(Icons.close),
                                        tooltip: 'Refuser',
                                      ),
                                      IconButton(
                                        onPressed:
                                            () => _confirmDecision(
                                              device,
                                              DeviceApprovalDecision.approve,
                                            ),
                                        icon: const Icon(Icons.check),
                                        tooltip: 'Autoriser',
                                      ),
                                    ],
                                  )
                              : null,
                    );
                  },
                ),
      ),
    );
  }

  String _statusLabel(AccountDeviceStatus status) => switch (status) {
    AccountDeviceStatus.pending => 'En attente',
    AccountDeviceStatus.active => 'Autorisé',
    AccountDeviceStatus.revoked => 'Révoqué',
  };

  IconData _platformIcon(String platform) => switch (platform) {
    'android' || 'ios' => Icons.smartphone,
    'windows' || 'macos' => Icons.computer,
    _ => Icons.devices_other,
  };
}
