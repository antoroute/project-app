import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';

class MyDevicesScreen extends StatefulWidget {
  final String groupId;
  const MyDevicesScreen({super.key, required this.groupId});

  @override
  State<MyDevicesScreen> createState() => _MyDevicesScreenState();
}

class _MyDevicesScreenState extends State<MyDevicesScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final auth = context.read<AuthProvider>();
      final group = context.read<GroupProvider>();
      if (auth.userId != null) {
        await group.fetchMyDevices(widget.groupId, auth.userId!);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = context.watch<GroupProvider>();
    final devices = group.myDevices;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes appareils')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : devices.isEmpty
              ? const Center(child: Text('Aucun appareil'))
              : ListView.separated(
                  itemCount: devices.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final d = devices[i];
                    return ListTile(
                      leading: const Icon(Icons.devices),
                      title: Text(d['deviceId'] as String),
                      subtitle: Text('v${d['key_version'] ?? 1} - ${d['status'] ?? 'active'}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_forever),
                        tooltip: 'Révoquer',
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Révoquer l\'appareil ?'),
                              content: Text('DeviceId: ${d['deviceId']}'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Révoquer')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await group.revokeMyDevice(widget.groupId, d['deviceId'] as String);
                            if (mounted) setState(() {});
                          }
                        },
                      ),
                    );
                  },
                ),
    );
  }
}


