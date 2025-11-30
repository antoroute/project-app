// Legacy creation flow code removed for v2

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/group_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/services/snackbar_service.dart';
import '../../core/services/websocket_service.dart';
import '../../core/services/navigation_tracker_service.dart';
import '../../core/services/in_app_notification_service.dart';
import '../../core/services/notification_badge_service.dart';
import 'conversation_screen.dart';

/// Écran de liste des conversations d'un groupe : liste des conversations et création de conversation.
class GroupConversationListScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final Widget? bottomNavigationBar;
  final int? currentNavIndex;

  const GroupConversationListScreen({
    Key? key,
    required this.groupId,
    required this.groupName,
    this.bottomNavigationBar,
    this.currentNavIndex,
  }) : super(key: key);

  @override
  State<GroupConversationListScreen> createState() => _GroupConversationListScreenState();
}

class _GroupConversationListScreenState extends State<GroupConversationListScreen> {
  bool _loading = true;
  // bool _isCreator = false; // unused in v2
  final Set<String> _selectedUserIds = {};

  // Cache pour éviter les logs répétitifs
  int _lastMembers = -1;
  int _lastConvos = -1;

  // Legacy fields removed

  @override
  void initState() {
    super.initState();
    
    // Enregistrer l'écran actuel
    NavigationTrackerService().setCurrentScreen('GroupConversationListScreen');
    
    _loadGroupData();
    WebSocketService.instance.onGroupJoined = (groupId, userId, approverId) {
      if (mounted) {
        _loadGroupData();
        SnackbarService.showInfo(
          context,
          'Vous avez rejoint un nouveau groupe',
        );
      }
    };
    
    // Vérifier les notifications en attente après le premier frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotifications();
    });
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Écouter les changements du ConversationProvider pour afficher les nouvelles notifications
    final convProvider = context.read<ConversationProvider>();
    convProvider.addListener(_onConversationProviderChanged);
  }
  
  @override
  void dispose() {
    final convProvider = context.read<ConversationProvider>();
    convProvider.removeListener(_onConversationProviderChanged);
    super.dispose();
  }
  
  void _onConversationProviderChanged() {
    if (mounted) {
      _checkPendingNotifications();
    }
  }
  
  /// Vérifie et affiche les notifications in-app en attente
  void _checkPendingNotifications() {
    if (!mounted) return;
    
    final convProvider = context.read<ConversationProvider>();
    final notifications = convProvider.getPendingInAppNotifications();
    
    if (notifications.isEmpty) {
      return; // Pas de nouvelles notifications
    }
    
    debugPrint('🔔 [GroupConversationList] ${notifications.length} notification(s) en attente à afficher');
    
    for (final notification in notifications) {
      if (!mounted) return;
      
      final type = notification['type'] as String;
      debugPrint('🔔 [GroupConversationList] Affichage notification: $type');
      
      if (type == 'new_message') {
        final conversationId = notification['conversationId'] as String;
        final senderName = notification['senderName'] as String;
        final messageText = notification['messageText'] as String;
        
        debugPrint('🔔 [GroupConversationList] Notification nouveau message: $senderName - $messageText');
        
        InAppNotificationService.showNewMessageNotification(
          context: context,
          senderName: senderName,
          messageText: messageText,
          conversationId: conversationId,
          onTap: () {
            // Naviguer vers la conversation
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationScreen(conversationId: conversationId),
              ),
            );
          },
        );
      } else if (type == 'new_conversation') {
        final conversationId = notification['conversationId'] as String;
        final groupName = notification['groupName'] as String?;
        
        debugPrint('🔔 [GroupConversationList] Notification nouvelle conversation: $conversationId');
        
        InAppNotificationService.showNewConversationNotification(
          context: context,
          conversationId: conversationId,
          groupName: groupName ?? widget.groupName,
          onTap: () {
            // Naviguer vers la conversation
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConversationScreen(conversationId: conversationId),
              ),
            );
          },
        );
      }
    }
  }

  Future<void> _loadGroupData() async {
    setState(() => _loading = true);

    // final String? currentUserId = context.read<AuthProvider>().userId; // unused
    final groupProv = context.read<GroupProvider>();
    final convProv  = context.read<ConversationProvider>();

    try {
      debugPrint('🔄 Loading group detail for ${widget.groupId}');
      await groupProv.fetchGroupDetail(widget.groupId);
      debugPrint('✅ Group detail loaded');
      
      await groupProv.fetchGroupMembers(widget.groupId);
      debugPrint('✅ Group members loaded');
      
      await convProv.fetchConversations();
      debugPrint('✅ Conversations loaded');
      // Note: L'abonnement aux conversations est géré automatiquement par fetchConversations()
      // qui s'abonne à toutes les conversations auxquelles l'utilisateur a accès
      // Le backend vérifie les permissions avant d'envoyer les messages

      // v2: creator flag unused
    } catch (error) {
      SnackbarService.showError(
        context,
        'Erreur chargement : $error',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }


  Future<void> _createConversation() async {
    final String? currentUserId = context.read<AuthProvider>().userId;
    if (currentUserId == null) {
      SnackbarService.showError(context, 'Utilisateur non authentifié');
      return;
    }

    final convProv = context.read<ConversationProvider>();

    // 1) Compose la liste des participants (sans l'utilisateur courant, automatiquement inclus côté backend)
    final selectedUserIdsWithoutMe = _selectedUserIds.where((id) => id != currentUserId).toList();

    // 2) V2: conversation creation simple pour l'instant
    const String conversationType = 'subset'; // ou 'private' selon les besoins

    // 3) Appel à l'API
    try {
      final String newConversationId = await convProv.createConversation(
        widget.groupId,
        selectedUserIdsWithoutMe,
        conversationType,
      );
      SnackbarService.showSuccess(context, 'Conversation créée !');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ConversationScreen(
            conversationId: newConversationId,
          ),
        ),
      );
    } catch (error) {
      SnackbarService.showError(context, 'Erreur création : $error');
    } finally {
      // Réinitialisation
      setState(() {
        _selectedUserIds.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupProv = context.watch<GroupProvider>();
    final convProv  = context.watch<ConversationProvider>();
    final String? currentUserId = context.read<AuthProvider>().userId;
    
    // Écouter les changements du service de badges
    return ChangeNotifierProvider.value(
      value: NotificationBadgeService(),
      child: Consumer<NotificationBadgeService>(
        builder: (context, badgeService, child) {
          return _buildContent(context, groupProv, convProv, currentUserId);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, GroupProvider groupProv, ConversationProvider convProv, String? currentUserId) {
    
    // Debug info - seulement si les valeurs ont changé
    final membersCount = groupProv.members.length;
    final convosCount = convProv.conversations.length;
    if (_lastMembers != membersCount || _lastConvos != convosCount) {
      debugPrint('🔄 Group Detail - Members: $membersCount, Conversations: $convosCount');
      _lastMembers = membersCount;
      _lastConvos = convosCount;
    }

    // Filtre : exclut l'utilisateur courant de la liste des sélectionnables
    final members = List<Map<String, dynamic>>.from(groupProv.members)
        .where((member) => member['userId'] != currentUserId)
        .toList();
    members.sort((a, b) => (a['username'] as String).compareTo(b['username'] as String));

    // Filtre des conversations du groupe
    final convs = convProv.conversations
        .where((c) => c.groupId == widget.groupId)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        automaticallyImplyLeading: false, // Supprimer le bouton retour
      ),

      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [

                // Section de création de conversation  
                Card(
                  margin: const EdgeInsets.all(8.0),
                  child: ExpansionTile(
                    title: Row(
                      children: [
                        const Icon(Icons.add_circle_outline, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(
                          child: const Text('💬 Créer une conversation', 
                            style: TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_selectedUserIds.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            constraints: const BoxConstraints(minWidth: 24),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${_selectedUserIds.length}', 
                              style: const TextStyle(color: Colors.white, fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Sélectionnez les participants :', 
                              style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            const Text('(Vous êtes automatiquement inclus)', 
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 12),
                            if (members.isEmpty)
                              const Card(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Text('Aucun autre membre dans ce groupe', 
                                    style: TextStyle(color: Colors.grey)),
                                ),
                              )
                            else ...[
                              Container(
                                constraints: const BoxConstraints(maxHeight: 200),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: members.length,
                                  itemBuilder: (context, index) {
                                    final member = members[index];
                                    final isSelected = _selectedUserIds.contains(member['userId']);
                                    return CheckboxListTile(
                                      dense: true,
                                      title: Text(member['username'] ?? member['email'] ?? 'Utilisateur',
                                        style: const TextStyle(fontSize: 14)),
                                      subtitle: Text(member['email'] ?? '', 
                                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      value: isSelected,
                                      onChanged: (bool? checked) {
                                        setState(() {
                                          if (checked == true) {
                                            _selectedUserIds.add(member['userId']);
                                          } else {
                                            _selectedUserIds.remove(member['userId']);
                                          }
                                        });
                                      },
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: () => setState(() => _selectedUserIds.clear()),
                                    icon: const Icon(Icons.clear, size: 16),
                                    label: const Text('Effacer'),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => setState(() {
                                      _selectedUserIds.clear();
                                      _selectedUserIds.addAll(members.map((m) => m['userId'] as String));
                                    }),
                                    icon: const Icon(Icons.select_all, size: 16),
                                    label: const Text('Tout sélectionner'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // Liste des conversations

                if (convs.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        const Text(
                          'Conversations',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _loadGroupData,
                          tooltip: 'Actualiser',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Consumer<NotificationBadgeService>(
                      builder: (context, badgeService, child) {
                        return ListView.builder(
                          itemCount: convs.length,
                          itemBuilder: (context, index) {
                            final conv = convs[index];
                            final hasNewMessages = badgeService.conversationsWithNewMessages.contains(conv.conversationId);
                            
                            return ListTile(
                              leading: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  const Icon(Icons.chat),
                                  if (hasNewMessages)
                                    Positioned(
                                      right: -4,
                                      top: -4,
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white, width: 1),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Conversation ${conv.conversationId.substring(0, 8)}...',
                                      style: TextStyle(
                                        fontWeight: hasNewMessages ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  if (hasNewMessages)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.red,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Text(
                                        'Nouveau',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Text('Type: ${conv.type}'),
                              onTap: () {
                                // Marquer la conversation comme lue
                                badgeService.markConversationAsRead(conv.conversationId);
                                
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ConversationScreen(
                                      conversationId: conv.conversationId,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                  ),
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Conversations',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Expanded(
                    child: Center(child: Text('Aucune conversation créée')),
                  ),
                ],
              ],
            ),

      floatingActionButton: _selectedUserIds.isNotEmpty
          ? FloatingActionButton(
              onPressed: _createConversation,
              child: const Icon(Icons.chat),
              tooltip: 'Créer conversation',
            )
          : null,
      bottomNavigationBar: widget.bottomNavigationBar,
    );
  }
}

