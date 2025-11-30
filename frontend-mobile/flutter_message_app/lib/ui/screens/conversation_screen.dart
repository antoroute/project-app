import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/providers/auth_provider.dart';
import '../../core/providers/conversation_provider.dart';
import '../../core/models/message.dart';
import '../../core/crypto/message_cipher_v2.dart';
import '../../core/services/session_device_service.dart';
import '../helpers/extensions.dart';
import '../widgets/message_bubble.dart';

class ConversationScreen extends StatefulWidget {
  final String conversationId;
  const ConversationScreen({Key? key, required this.conversationId})
      : super(key: key);

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ConversationProvider _conversationProvider;

  static const int _messagesPerPage = 20;  // Messages chargés par pagination
  
  bool _isLoading = false;
  bool _initialDecryptDone = false;
  bool _hasMoreOlderMessages = true;
  
  // Timer pour les indicateurs de frappe
  Timer? _typingTimer;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // ValueNotifier pour les mises à jour ultra-granulaires
  final ValueNotifier<String?> _messageUpdateNotifier = ValueNotifier<String?>(null);
  
  // 🚀 OPTIMISATION: Gérer les Futures de déchiffrement pour annulation lors de la navigation
  final Set<Future<void>> _activeDecryptionFutures = <Future<void>>{};

  @override
  void initState() {
    super.initState();
    _conversationProvider = context.read<ConversationProvider>();

    // Pas d'écoute du scroll - géré par NotificationListener
    
    // WebSocket déjà connecté au niveau de l'app, juste s'abonner à la conversation
    _conversationProvider.subscribe(widget.conversationId);
    _conversationProvider.addListener(_onMessagesUpdated);

    // 🚀 OPTIMISATION: Lancer le chargement en arrière-plan sans bloquer l'affichage
    // L'écran s'affiche immédiatement avec un indicateur de chargement
    // Les messages s'afficheront progressivement via les notifications du provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  /// Vérifie si l'utilisateur est proche du bas (reverse:true)
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.offset < 80.0; // reverse:true -> 0 == bas
  }

  /// Gestionnaire de notification de scroll pour reverse:true
  bool _onScrollNotification(ScrollNotification n) {
    // CORRECTION: Avec reverse:true, on détecte quand on approche du haut (maxScrollExtent)
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - 100 && _hasMoreOlderMessages && !_isLoading) {
      debugPrint('🔄 Scroll détecté - Chargement messages anciens...');
      _loadOlderPreservingOffset();
    }
    return false;
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    try {
      // 🚀 OPTIMISATION: Charger les messages EN PREMIER pour affichage immédiat
      // L'écran est déjà affiché, on charge les messages en arrière-plan
      
      // 1) Charger les messages en premier (peut être depuis le stockage local = instantané)
      // Cette opération notifie automatiquement les listeners quand les messages arrivent
      await _conversationProvider.fetchMessages(
        context, 
        widget.conversationId,
        limit: _messagesPerPage,  // Limiter à 25 messages au lieu de TOUT charger
      );
      
      // 2) Les messages sont maintenant dans le provider et s'affichent automatiquement
      // via le watch() dans le build()
      if (!mounted) return;
      setState(() => _isLoading = false);
      
      // 3) Déchiffrement progressif en arrière-plan (non-bloquant)
      _startProgressiveDecryption();
      _initialDecryptDone = true;
      
      // 4) Opérations non-critiques en parallèle (ne bloquent pas l'UI)
      // Ces opérations peuvent se faire en arrière-plan sans bloquer l'affichage
      // Ne pas attendre ces futures - elles s'exécutent en arrière-plan
      Future.wait<void>([
        // Charger les détails de la conversation
        _conversationProvider.fetchConversationDetail(
          context, widget.conversationId,
        ).then((_) => null).catchError((e) {
          debugPrint('⚠️ Erreur chargement détails conversation: $e');
          return null;
        }),
        
        // POST read receipt (non-bloquant)
        _conversationProvider.postRead(widget.conversationId).then((_) => null).catchError((e) {
          debugPrint('⚠️ Erreur post read: $e');
          return null;
        }),
        
        // Fetch initial readers (non-bloquant)
        context.read<ConversationProvider>().refreshReaders(widget.conversationId).then((_) => null).catchError((e) {
          debugPrint('⚠️ Erreur refresh readers: $e');
          return null;
        }),
        
        // Pré-charger les clés de groupe (non-bloquant, en arrière-plan)
        _conversationProvider.preloadGroupKeys(widget.conversationId).then((_) => null).catchError((e) {
          debugPrint('⚠️ Erreur pré-chargement clés: $e');
          return null;
        }),
      ]).catchError((e) {
        debugPrint('⚠️ Erreur opérations parallèles: $e');
        return <void>[];
      });

    } catch (e) {
      debugPrint('❌ Erreur chargement conversation : $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 🚀 OPTIMISATION SIGNAL: Déchiffrement parallèle et prioritaire
  /// - Messages visibles déchiffrés immédiatement en parallèle
  /// - Messages non visibles déchiffrés en arrière-plan par lots
  void _startProgressiveDecryption() {
    final messages = _conversationProvider.messagesFor(widget.conversationId);
    if (messages.isEmpty) return;
    
    // 🚀 PRIORITÉ 1: Déchiffrer les 5 derniers messages (visibles) IMMÉDIATEMENT en parallèle
    // 🚀 OPTIMISATION: Réduit de 10 à 5 pour éviter les freezes sur mobile
    final visibleMessages = messages.length > 5 
        ? messages.sublist(messages.length - 5)
        : messages;
    
    // 🚀 OPTIMISATION: Déchiffrer seulement les messages non déchiffrés ou sans signature vérifiée
    final visibleFutures = <Future<void>>[];
    for (final msg in visibleMessages) {
      // Déchiffrer si pas encore déchiffré OU si signature pas vérifiée
      if ((msg.decryptedText == null || msg.signatureValid != true) && msg.v2Data != null) {
        final future = _decryptMessageUltraFluid(msg);
        visibleFutures.add(future);
        // 🚀 OPTIMISATION: Suivre les Futures actifs pour annulation si nécessaire
        _activeDecryptionFutures.add(future);
        future.whenComplete(() {
          _activeDecryptionFutures.remove(future);
        });
      }
    }
    
    // Lancer tous les déchiffrements visibles en parallèle
    Future.wait(visibleFutures).then((_) {
      if (mounted) {
        _messageUpdateNotifier.value = 'batch_visible_done';
      }
    }).catchError((e) {
      // Ignorer les erreurs si le widget est détruit
      if (mounted) {
        debugPrint('⚠️ Erreur déchiffrement batch visible: $e');
      }
    });
    
    // 🚀 PRIORITÉ 2: Déchiffrer les autres messages en arrière-plan par petits lots
    // CORRECTION: Commencer par les messages les plus récents (juste avant les 5 visibles)
    // puis remonter vers les plus anciens
    if (messages.length > 5) {
      final backgroundMessages = messages.sublist(0, messages.length - 5);
      // CORRECTION: Inverser l'ordre pour déchiffrer d'abord les plus récents
      final reversedBackgroundMessages = backgroundMessages.reversed.toList();
      _decryptBackgroundMessages(reversedBackgroundMessages);
    }
  }
  
  /// Déchiffre les messages en arrière-plan par lots pour éviter de bloquer l'UI
  /// CORRECTION: Les messages sont passés dans l'ordre inverse (plus récents en premier)
  void _decryptBackgroundMessages(List<Message> messages) {
    // 🚀 OPTIMISATION MOBILE: Réduire le parallélisme et augmenter le délai pour éviter les freezes
    const batchSize = 3; // Déchiffrer seulement 3 messages à la fois (au lieu de 10)
    const delayBetweenBatches = 150; // 150ms entre chaque lot (au lieu de 30ms) pour laisser respirer l'UI
    
    int batchIndex = 0;
    
    void processBatch() {
      if (batchIndex * batchSize >= messages.length) return;
      if (!mounted) return;
      
      final start = batchIndex * batchSize;
      final end = (start + batchSize).clamp(0, messages.length);
      final batch = messages.sublist(start, end);
      
        // 🚀 OPTIMISATION: Déchiffrer seulement les messages non déchiffrés ou sans signature vérifiée
        final futures = <Future<void>>[];
        for (final msg in batch) {
          // Déchiffrer si pas encore déchiffré OU si signature pas vérifiée
          if ((msg.decryptedText == null || msg.signatureValid != true) && msg.v2Data != null) {
            final future = _decryptMessageUltraFluid(msg).catchError((e) {
              debugPrint('⚠️ Erreur déchiffrement arrière-plan ${msg.id}: $e');
            });
            futures.add(future);
            // 🚀 OPTIMISATION: Suivre les Futures actifs pour annulation si nécessaire
            _activeDecryptionFutures.add(future);
            future.whenComplete(() {
              _activeDecryptionFutures.remove(future);
            });
          }
        }
      
      Future.wait(futures).then((_) {
        if (mounted) {
          _messageUpdateNotifier.value = 'batch_${batchIndex}';
        }
        
        // Traiter le lot suivant après un court délai
        batchIndex++;
        if (batchIndex * batchSize < messages.length && mounted) {
          Future.delayed(Duration(milliseconds: delayBetweenBatches), processBatch);
        }
      }).catchError((e) {
        // Ignorer les erreurs si le widget est détruit
        if (mounted) {
          debugPrint('⚠️ Erreur déchiffrement batch arrière-plan: $e');
        }
      });
    }
    
    // Démarrer le traitement des lots
    Future.delayed(Duration(milliseconds: 100), processBatch);
  }
  
  /// 🚀 OPTIMISATION: Déchiffrement rapide puis vérification de signature en arrière-plan
  /// - Déchiffre rapidement d'abord (decryptFast) pour affichage immédiat
  /// - Vérifie la signature ensuite (decrypt) en arrière-plan
  Future<void> _decryptMessageUltraFluid(Message message) async {
    // Si déjà déchiffré ET signature vérifiée, ne rien faire
    if (message.decryptedText != null && message.signatureValid == true) {
      return;
    }
    
    try {
      final currentUserId = context.read<AuthProvider>().userId;
      if (currentUserId == null) return;
      
      final myDeviceId = await SessionDeviceService.instance.getOrCreateDeviceId();
      final groupId = message.v2Data!['groupId'] as String;
      
      // 🚀 ÉTAPE 1: Déchiffrement rapide (sans vérification) pour affichage immédiat
      if (message.decryptedText == null) {
        final fastResult = await MessageCipherV2.decryptFast(
          groupId: groupId,
          myUserId: currentUserId,
          myDeviceId: myDeviceId,
          messageV2: message.v2Data!,
          keyDirectory: _conversationProvider.keyDirectory,
        );
        
        final decryptedText = utf8.decode(fastResult['decryptedText'] as Uint8List);
        message.decryptedText = decryptedText;
        message.signatureValid = false; // Temporairement non vérifié
        
        // Mise à jour UI immédiate
        if (mounted) {
          _messageUpdateNotifier.value = message.id;
        }
      }
      
      // 🚀 ÉTAPE 2: Vérification de signature en arrière-plan (non-bloquant)
      // OPTIMISATION: Utiliser decryptMessageIfNeeded qui utilise le cache de clés
      if (message.signatureValid != true) {
        // Vérifier la signature en arrière-plan sans bloquer l'UI
        // Utiliser decryptMessageIfNeeded qui optimise avec le cache de clés
        _conversationProvider.decryptMessageIfNeeded(message).then((_) {
          // decryptMessageIfNeeded met déjà à jour message.signatureValid
          // et sauvegarde dans la DB et notifie les listeners
          
          // CORRECTION: Forcer la mise à jour de l'UI avec un délai pour s'assurer
          // que le message dans le provider est bien mis à jour
          // decryptMessageIfNeeded appelle déjà notifyListeners(), donc pas besoin de le rappeler
          Future.delayed(Duration(milliseconds: 50), () {
            if (mounted) {
              // Déclencher le rebuild du ValueListenableBuilder
              _messageUpdateNotifier.value = message.id;
            }
          });
        }).catchError((e) {
          debugPrint('⚠️ Erreur vérification signature message ${message.id}: $e');
          // En cas d'erreur, garder signatureValid = false
        });
      }
      
     } catch (e) {
       debugPrint('⚠️ Erreur déchiffrement ultra-fluide message ${message.id}: $e');
       // Fallback sur le déchiffrement normal si nécessaire
       try {
         await _conversationProvider.decryptMessageIfNeeded(message);
         
         if (mounted) {
           _messageUpdateNotifier.value = message.id;
         }
       } catch (fallbackError) {
         debugPrint('❌ Erreur fallback déchiffrement message ${message.id}: $fallbackError');
       }
     }
  }

  /// Charge les messages plus anciens en préservant la position de scroll (reverse:true)
  Future<void> _loadOlderPreservingOffset() async {
    if (_isLoading || !_hasMoreOlderMessages) {
      debugPrint('⏸️ Chargement ignoré - isLoading: $_isLoading, hasMore: $_hasMoreOlderMessages');
      return;
    }
    
    if (!_scrollController.hasClients) {
      debugPrint('⏸️ ScrollController non disponible');
      return;
    }
    
    final before = _scrollController.position.maxScrollExtent;
    final currentMessages = _conversationProvider.messagesFor(widget.conversationId);
    debugPrint('🔄 Début chargement - Messages actuels: ${currentMessages.length}, ScrollExtent: $before');
    
    setState(() => _isLoading = true);
    try {
      final hasMore = await _conversationProvider.fetchOlderMessages(
        context,
        widget.conversationId,
        limit: _messagesPerPage,
      );
      
      final newMessages = _conversationProvider.messagesFor(widget.conversationId);
      debugPrint('📄 Chargement terminé - Nouveaux messages: ${newMessages.length - currentMessages.length}, hasMore: $hasMore');
      
      // Arrêter le chargement s'il n'y a plus de messages
      if (!hasMore) {
        _hasMoreOlderMessages = false;
        debugPrint('📄 Plus de messages anciens à charger');
      }
      
      // Préserver la position de scroll après ajout des nouveaux messages
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final after = _scrollController.position.maxScrollExtent;
        final offsetDiff = after - before;
        debugPrint('📍 Ajustement scroll - Avant: $before, Après: $after, Différence: $offsetDiff');
        _scrollController.jumpTo(_scrollController.offset + offsetDiff);
      });
    } catch (e) {
      debugPrint('❌ Erreur chargement messages anciens: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onMessagesUpdated() {
    if (!_initialDecryptDone) return;
    
    // Auto-scroll seulement si l'utilisateur est proche du bas (reverse:true)
    if (_isNearBottom()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0, // reverse:true -> bas
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    } else {
      // Afficher un indicateur "Nouveaux messages" si pas en bas
      // TODO: Implémenter le pill "Nouveaux messages"
    }
  }

  /// 🚀 OPTIMISATION: Envoi de message non-bloquant
  /// Permet d'envoyer un message même pendant le déchiffrement
  Future<void> _onSendPressed() async {
    final plainText = _textController.text.trim();
    if (plainText.isEmpty) return;
    
    // Arrêter l'indicateur de frappe avant d'envoyer
    _conversationProvider.stopTyping(widget.conversationId);
    _typingTimer?.cancel();
    
    // 🚀 OPTIMISATION: Vider le champ immédiatement pour feedback UI instantané
    _textController.clear();
    
    // 🚀 OPTIMISATION: Envoyer en arrière-plan sans bloquer l'UI
    // Le déchiffrement peut continuer en parallèle
    _conversationProvider.sendMessage(context, widget.conversationId, plainText).catchError((e) {
      // En cas d'erreur, restaurer le texte pour que l'utilisateur puisse réessayer
      if (mounted) {
        _textController.text = plainText;
        debugPrint('❌ Erreur envoi message: $e');
      }
    });
  }
  
  /// Gère les événements de frappe
  void _onTextChanged(String text) {
    if (text.isNotEmpty) {
      // Démarrer l'indicateur de frappe
      _conversationProvider.startTyping(widget.conversationId);
      
      // Programmer l'arrêt de l'indicateur après 2 secondes d'inactivité
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () {
        _conversationProvider.stopTyping(widget.conversationId);
      });
    } else {
      // Arrêter l'indicateur si le champ est vide
      _conversationProvider.stopTyping(widget.conversationId);
      _typingTimer?.cancel();
    }
  }
  
  /// Construit l'indicateur de frappe
  Widget _buildTypingIndicator() {
    final typingUsernames = _conversationProvider.getTypingUsernames(widget.conversationId);
    if (typingUsernames.isEmpty) return const SizedBox.shrink();
    
    // Filtrer notre propre utilisateur (comparer par pseudo)
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final currentUsername = authProvider.username ?? '';
    final otherTypingUsers = typingUsernames.where((username) => username != currentUsername).toList();
    
    if (otherTypingUsers.isEmpty) return const SizedBox.shrink();
    
    final typingText = otherTypingUsers.length == 1
        ? '${otherTypingUsers.first} est en train d\'écrire...'
        : '${otherTypingUsers.length} personnes sont en train d\'écrire...';
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        typingText,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _conversationProvider.unsubscribe(widget.conversationId);
    _conversationProvider.removeListener(_onMessagesUpdated);
    _textController.dispose();
    _scrollController.dispose();
    _messageUpdateNotifier.dispose(); // Nettoyer le ValueNotifier
    _typingTimer?.cancel(); // Annuler le timer de frappe
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = context
        .watch<ConversationProvider>()
        .messagesFor(widget.conversationId);
    
    // CORRECTION: Toujours afficher le Scaffold, même si messages vides
    // pour éviter l'écran noir sur conversations nouvellement créées
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Conversation',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
            _WebSocketStatusIndicator(),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: Column(
        children: [
          // Zone de messages avec NotificationListener
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: messages.isEmpty && _isLoading
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text(
                            'Chargement des messages...',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    )
                  : messages.isEmpty && !_isLoading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32.0),
                            child: Text(
                              'Aucun message pour le moment.\nCommencez la conversation !',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                      reverse: true, // Clé anti-jump
                      controller: _scrollController,
                      itemCount: messages.length + (_isLoading ? 1 : 0), // +1 pour l'indicateur de chargement
                      itemBuilder: (_, i) {
                        // CORRECTION: Gérer l'indicateur de chargement
                        if (_isLoading && i == messages.length) {
                          return const Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        
                        final msg = messages[messages.length - 1 - i]; // dernier d'abord
                        final currentUserId = context.read<AuthProvider>().userId ?? '';
                        
                        // Calculer sameAsPrevious et sameAsNext pour l'affichage des vignettes
                        final sameAsPrevious = i < messages.length - 1 && 
                            messages[messages.length - 2 - i].senderId == msg.senderId;
                        final sameAsNext = i > 0 && 
                            messages[messages.length - i].senderId == msg.senderId;
                        
                        // Vérifier si on doit afficher un indicateur de date
                        final msgDate = DateTime.fromMillisecondsSinceEpoch(msg.timestamp * 1000).toLocal();
                        final dateOnly = DateTime(msgDate.year, msgDate.month, msgDate.day);
                        
                        // Vérifier la date du message précédent pour savoir si on doit afficher l'en-tête de date
                        DateTime? previousDate;
                        if (i < messages.length - 1) {
                          final prevMsg = messages[messages.length - 2 - i];
                          final prevMsgDate = DateTime.fromMillisecondsSinceEpoch(prevMsg.timestamp * 1000).toLocal();
                          previousDate = DateTime(prevMsgDate.year, prevMsgDate.month, prevMsgDate.day);
                        }
                        
                        final showDateHeader = previousDate == null || previousDate != dateOnly;
                        
                        return Column(
                    children: [
                      // Indicateur de date
                      if (showDateHeader)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: Text(
                              dateOnly.toChatDateHeader(),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      
                      // Message avec ValueListenableBuilder pour mise à jour ultra-granulaire
                      ValueListenableBuilder<String?>(
                        valueListenable: _messageUpdateNotifier,
                        builder: (context, updatedMessageId, child) {
                          // CORRECTION: Re-lire le message depuis le provider pour avoir la version à jour
                          // Cela garantit que signatureValid est toujours à jour
                          final updatedMsg = _conversationProvider.messagesFor(widget.conversationId)
                              .firstWhere((m) => m.id == msg.id, orElse: () => msg);
                          
                          return MessageBubble(
                            key: ValueKey(updatedMsg.id), // Clé stable
                            isMe: updatedMsg.senderId == currentUserId,
                            text: updatedMsg.decryptedText ?? '[Chiffré]',
                            time: msgDate.toHm(),
                            signatureValid: updatedMsg.signatureValid, // CORRECTION: Lire depuis le message mis à jour
                            senderInitial: updatedMsg.senderId == currentUserId ? '' : updatedMsg.senderId[0].toUpperCase(),
                            senderUsername: context.read<ConversationProvider>().getUsernameForUser(updatedMsg.senderId),
                            senderUserId: updatedMsg.senderId,
                            conversationId: widget.conversationId,
                            sameAsPrevious: sameAsPrevious,
                            sameAsNext: sameAsNext,
                            maxWidth: context.maxBubbleWidth,
                            messageId: updatedMsg.id,
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          // Zone de saisie avec SafeArea pour Android
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Indicateur de frappe
                  _buildTypingIndicator(),
                  
                  // Zone de saisie
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          onChanged: _onTextChanged,
                          decoration: InputDecoration(
                            hintText: 'Tapez votre message...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surfaceVariant,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          maxLines: 4,
                          minLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        onPressed: _onSendPressed,
                        mini: true,
                        child: const Icon(Icons.send),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Widget pour afficher le statut de connexion WebSocket
class _WebSocketStatusIndicator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.green, // Simplifié pour l'instant
        shape: BoxShape.circle,
      ),
    );
  }
}
