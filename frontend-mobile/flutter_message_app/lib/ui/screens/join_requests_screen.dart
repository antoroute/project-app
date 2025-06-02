import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/group_provider.dart';
import '../../core/services/snackbar_service.dart';

class JoinRequestsScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final bool isCreator;

  const JoinRequestsScreen({
    Key? key,
    required this.groupId,
    required this.groupName,
    required this.isCreator,
  }) : super(key: key);

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() => _loading = true);
    try {
      // Tout le monde peut appeler GET /groups/:id/join-requests
      await Provider.of<GroupProvider>(context, listen: false)
          .fetchJoinRequests(widget.groupId);
    } catch (e) {
      SnackbarService.showError(context, 'Erreur chargement : $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _vote(String reqId, bool vote) async {
    try {
      await Provider.of<GroupProvider>(context, listen: false)
          .voteJoinRequest(widget.groupId, reqId, vote);
      await _loadRequests(); // met à jour les compteurs yes/no
    } catch (e) {
      SnackbarService.showError(context, 'Erreur vote : $e');
    }
  }

  Future<void> _handle(String reqId, String action) async {
    try {
      await Provider.of<GroupProvider>(context, listen: false)
          .handleJoinRequest(widget.groupId, reqId, action);
      SnackbarService.showSuccess(
        context,
        'Demande ${action == 'accept' ? 'acceptée' : 'refusée'}',
      );
      await _loadRequests(); // rafraîchit la liste
    } catch (e) {
      SnackbarService.showError(context, 'Erreur traitement : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final requests = Provider.of<GroupProvider>(context).joinRequests;

    return Scaffold(
      appBar: AppBar(title: Text('Demandes – ${widget.groupName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : requests.isEmpty
              ? const Center(child: Text('Aucune demande en attente'))
              : ListView.builder(
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    final req = requests[index];
                    final String id       = req['id'] as String;
                    final String username = req['username'] as String? ?? 'Inconnu';
                    // on transforme yesVotes / noVotes au cas où ce seraient des String
                    final dynamic yesRaw = req['yesVotes'];
                    final int yes = yesRaw is int
                        ? yesRaw
                        : int.tryParse(yesRaw?.toString() ?? '') ?? 0;
                    final dynamic noRaw = req['noVotes'];
                    final int no = noRaw is int
                        ? noRaw
                        : int.tryParse(noRaw?.toString() ?? '') ?? 0;

                    return ListTile(
                      title: Text(username),
                      subtitle: Text('👍 $yes — 👎 $no'),
                      trailing: widget.isCreator
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  icon: const Icon(Icons.check, color: Colors.green),
                                  tooltip: 'Accepter',
                                  onPressed: () => _handle(id, 'accept'),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.red),
                                  tooltip: 'Refuser',
                                  onPressed: () => _handle(id, 'reject'),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  icon: const Icon(Icons.thumb_up, color: Colors.blue),
                                  tooltip: 'Voter oui',
                                  onPressed: () => _vote(id, true),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.thumb_down, color: Colors.blue),
                                  tooltip: 'Voter non',
                                  onPressed: () => _vote(id, false),
                                ),
                              ],
                            ),
                    );
                  },
                ),
    );
  }
}
