import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/services/snackbar_service.dart';
import 'my_devices_screen.dart';
import 'join_requests_screen.dart';

/// Écran avec toutes les informations sur le groupe
class GroupDetailInfoScreen extends StatefulWidget {
  final String groupId;
  final String groupName;

  const GroupDetailInfoScreen({
    Key? key,
    required this.groupId,
    required this.groupName,
  }) : super(key: key);

  @override
  State<GroupDetailInfoScreen> createState() => _GroupDetailInfoScreenState();
}

class _GroupDetailInfoScreenState extends State<GroupDetailInfoScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGroupData();
  }

  Future<void> _loadGroupData() async {
    setState(() => _loading = true);
    final groupProv = context.read<GroupProvider>();
    try {
      await groupProv.fetchGroupDetail(widget.groupId);
      await groupProv.fetchGroupMembers(widget.groupId);
    } catch (error) {
      SnackbarService.showError(
        context,
        'Erreur chargement : $error',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupProv = context.watch<GroupProvider>();
    final groupDetail = groupProv.groupDetail;
    final members = groupProv.members;
    final String? currentUserId = context.read<AuthProvider>().userId;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        automaticallyImplyLeading: false, // Pas de bouton retour
        actions: [
          // Bouton QR code
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Voir QR code',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (bottomCtx) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        QrImageView(
                          data: widget.groupId,
                          version: QrVersions.auto,
                          size: 200.0,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Colors.black,
                          ),
                          dataModuleStyle: const QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  const Text(
                                    'ID du groupe',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.groupId,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.black,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy),
                              color: Colors.black,
                              tooltip: "Copier l'ID",
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: widget.groupId),
                                );
                                Navigator.of(bottomCtx).pop();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('ID copié !')),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          child: const Text('FERMER'),
                          onPressed: () => Navigator.of(bottomCtx).pop(),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          // Bouton 'Mes appareils'
          IconButton(
            icon: const Icon(Icons.devices),
            tooltip: 'Mes appareils',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MyDevicesScreen(groupId: widget.groupId),
                ),
              );
            },
          ),
          // Bouton demandes d'adhésion
          IconButton(
            icon: const Icon(Icons.how_to_reg),
            tooltip: "Demandes d'adhésion",
            onPressed: () {
              final bool isCreator = groupDetail != null && 
                  currentUserId != null &&
                  groupDetail['creatorId'] == currentUserId;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JoinRequestsScreen(
                    groupId: widget.groupId,
                    groupName: widget.groupName,
                    isCreator: isCreator,
                  ),
                ),
              ).then((_) {
                _loadGroupData();
              });
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadGroupData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Informations générales
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Informations du groupe',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (groupDetail != null) ...[
                            _buildInfoRow('ID', widget.groupId),
                            if (groupDetail['name'] != null)
                              _buildInfoRow('Nom', groupDetail['name']),
                            if (groupDetail['createdAt'] != null)
                              _buildInfoRow(
                                'Créé le',
                                _formatDate(groupDetail['createdAt']),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Membres du groupe
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Membres',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                '${members.length}',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (members.isEmpty)
                            const Text(
                              'Aucun membre',
                              style: TextStyle(color: Colors.grey),
                            )
                          else
                            ...members.map((member) {
                              final isCurrentUser =
                                  member['userId'] == currentUserId;
                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  child: Text(
                                    (member['username'] ?? member['email'] ?? 'U')
                                        .substring(0, 1)
                                        .toUpperCase(),
                                  ),
                                ),
                                title: Text(
                                  member['username'] ?? member['email'] ?? 'Utilisateur',
                                  style: TextStyle(
                                    fontWeight: isCurrentUser
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                                subtitle: Text(
                                  member['email'] ?? '',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: isCurrentUser
                                    ? Chip(
                                        label: const Text('Vous'),
                                        labelStyle: const TextStyle(fontSize: 10),
                                      )
                                    : null,
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label :',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(dynamic date) {
    if (date == null) return 'N/A';
    try {
      final dateTime = date is String ? DateTime.parse(date) : date as DateTime;
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    } catch (e) {
      return date.toString();
    }
  }
}

