import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/services/snackbar_service.dart';

class JoinRequestsScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final bool isCreator;

  const JoinRequestsScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.isCreator,
  });

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> {
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchRequests();
  }

  Future<void> _fetchRequests() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    final res = await http.get(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/join-requests'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 200) {
      setState(() {
        _requests = List<Map<String, dynamic>>.from(jsonDecode(res.body));
      });
    } else {
      SnackbarService.showError(context, 'Erreur chargement demandes : ${res.body}');
    }
    setState(() => _loading = false);
  }

  Future<void> _vote(String reqId, bool vote) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    final res = await http.post(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/join-requests/$reqId/vote'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({'vote': vote}),
    );
    if (res.statusCode == 200) {
      await _fetchRequests();
    } else {
      SnackbarService.showError(context, 'Erreur vote : ${res.body}');
    }
  }

  Future<void> _handle(String reqId, String action) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token!;
    final res = await http.post(
      Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/join-requests/$reqId/handle'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token'
      },
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode == 200) {
      SnackbarService.showSuccess(
        context,
        'Demande ${action == 'accept' ? 'acceptée' : 'refusée'}',
      );
      await _fetchRequests();
    } else {
      SnackbarService.showError(context, 'Erreur traitement : ${res.body}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Demandes – ${widget.groupName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _requests.isEmpty
              ? const Center(child: Text('Aucune demande en attente'))
              : ListView.builder(
                  itemCount: _requests.length,
                  itemBuilder: (_, i) {
                    final jr = _requests[i];
                    final id = jr['id'] as String;
                    final user = jr['username'] as String;
                    // S'assurer que yes/no sont des int
                    final yes = (jr['yesVotes'] is int)
                        ? jr['yesVotes'] as int
                        : int.tryParse(jr['yesVotes'].toString()) ?? 0;
                    final no = (jr['noVotes'] is int)
                        ? jr['noVotes'] as int
                        : int.tryParse(jr['noVotes'].toString()) ?? 0;

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                      child: ListTile(
                        title: Text(user),
                        subtitle: Text('👍 $yes    👎 $no'),
                        trailing: widget.isCreator
                            // Si je suis créateur : j’ai les boutons vert/rouge pour accepter/refuser
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.check, color: Colors.green),
                                    onPressed: () => _handle(id, 'accept'),
                                    tooltip: 'Accepter',
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, color: Colors.red),
                                    onPressed: () => _handle(id, 'reject'),
                                    tooltip: 'Refuser',
                                  ),
                                ],
                              )
                            // Sinon : je ne peux que voter 👍/👎
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.thumb_up, color: Colors.green),
                                    onPressed: () => _vote(id, true),
                                    tooltip: 'Voter Oui',
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.thumb_down, color: Colors.red),
                                    onPressed: () => _vote(id, false),
                                    tooltip: 'Voter Non',
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                ),
    );
  }
}
