import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/providers/conversation_provider.dart';

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
                    final status = d['status'] as String? ?? 'active';
                    final isRevoked = status == 'revoked';
                    return ListTile(
                      leading: Icon(isRevoked ? Icons.devices_other : Icons.devices, 
                                   color: isRevoked ? Colors.grey : null),
                      title: Text(d['deviceId'] as String, 
                                  style: TextStyle(
                                    decoration: isRevoked ? TextDecoration.lineThrough : null,
                                    color: isRevoked ? Colors.grey : null,
                                  )),
                      subtitle: Text('v${d['key_version'] ?? 1} - ${isRevoked ? 'révoqué' : 'actif'}'),
                      trailing: isRevoked 
                        ? const Icon(Icons.block, color: Colors.grey)
                        : IconButton(
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
                                // CORRECTION: Rafraîchir les données après révocation
                                // revokeMyDevice appelle maintenant fetchMyDevices qui met à jour la liste
                                await group.revokeMyDevice(widget.groupId, d['deviceId'] as String);
                                
                                // CORRECTION CRITIQUE: Invalider le cache des clés pour que les autres devices
                                // ne puissent plus utiliser les clés du device révoqué
                                try {
                                  final conversationProvider = context.read<ConversationProvider>();
                                  conversationProvider.keyDirectory.invalidateCache(widget.groupId);
                                } catch (e) {
                                  // Si ConversationProvider n'est pas disponible, ce n'est pas critique
                                  // Le cache sera invalidé lors du prochain fetchGroupDevices
                                }
                                
                                // Le notifyListeners() dans fetchMyDevices mettra à jour l'UI automatiquement
                                // grâce à context.watch<GroupProvider>()
                              }
                            },
                          ),
                    );
                  },
                ),
    );
  }
}


