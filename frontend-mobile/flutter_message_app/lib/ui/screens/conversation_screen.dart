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
import '../../core/services/performance_benchmark.dart';
import '../../core/services/navigation_tracker_service.dart';
import '../../core/services/notification_badge_service.dart';
import '../../core/services/websocket_service.dart';
import '../../core/services/websocket_heartbeat_service.dart';
import '../../core/services/network_monitor_service.dart';
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
  bool _hasMoreOlderMessages = true;
  
  // 🚀 CORRECTION: Flag pour bloquer la détection de scroll pendant le chargement
  // Évite les déclenchements multiples qui causent des chargements en cascade
  bool _isScrollDetectionBlocked = false;
  
  // 🚀 CORRECTION: Dernière position de scroll détectée pour éviter les déclenchements trop fréquents
  double? _lastScrollTriggerPosition;
  
  // Timer pour les indicateurs de frappe
  Timer? _typingTimer;

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  // ValueNotifier pour les mises à jour ultra-granulaires
  final ValueNotifier<String?> _messageUpdateNotifier = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _conversationProvider = context.read<ConversationProvider>();

    // Enregistrer que cette conversation est ouverte
    NavigationTrackerService().setConversationOpen(widget.conversationId);
    NavigationTrackerService().setCurrentScreen('ConversationScreen');

    // Marquer la conversation comme lue (plus de badge)
    NotificationBadgeService().markConversationAsRead(widget.conversationId);

    // Pas d'écoute du scroll - géré par NotificationListener
    
    // WebSocket déjà connecté au niveau de l'app, juste s'abonner à la conversation
    _conversationProvider.subscribe(widget.conversationId);
    _conversationProvider.addListener(_onMessagesUpdated);

    // 🚀 OPTIMISATION: Lancer le chargement en arrière-plan sans bloquer l'affichage
    // L'écran s'affiche immédiatement avec un indicateur de chargement
    // Les messages s'afficheront progressivement via les notifications du provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _checkPendingNotifications();
    });
  }
  
  /// Vérifie et affiche les notifications in-app en attente
  void _checkPendingNotifications() {
    final notifications = _conversationProvider.getPendingInAppNotifications();
    for (final notification in notifications) {
      if (!mounted) return;
      
      final type = notification['type'] as String;
      if (type == 'new_message') {
        final conversationId = notification['conversationId'] as String;
        
        // CORRECTION: Ne plus afficher de notification texte pour les nouveaux messages
        // Les badges suffisent pour indiquer qu'il y a de nouveaux messages
        if (conversationId != widget.conversationId) {
          debugPrint('🔔 [ConversationScreen] Nouveau message dans autre conversation (badge uniquement, pas de notification texte)');
        }
      }
    }
  }

  /// Vérifie si l'utilisateur est proche du bas (reverse:true)
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.offset < 80.0; // reverse:true -> 0 == bas
  }

  /// Gestionnaire de notification de scroll pour reverse:true
  bool _onScrollNotification(ScrollNotification n) {
    // 🚀 CORRECTION: Bloquer complètement la détection pendant le chargement
    // pour éviter les déclenchements multiples et les chargements en cascade
    if (_isScrollDetectionBlocked || _isLoading) {
      return false;
    }
    
    // CORRECTION: Avec reverse:true, on détecte quand on approche du haut (maxScrollExtent)
    // Ne déclencher que sur ScrollUpdate pour éviter les déclenchements multiples
    if (n is ScrollUpdateNotification) {
      final pixels = n.metrics.pixels;
      final maxExtent = n.metrics.maxScrollExtent;
      
      // 🚀 CORRECTION: Vérifier que maxExtent est valide (pas 0) et qu'on a encore des messages
      if (maxExtent <= 0 || !_hasMoreOlderMessages) {
        return false;
      }
      
      // 🚀 CORRECTION: Seuil plus élevé (200px) et vérifier qu'on n'a pas déjà déclenché à cette position
      // Évite les déclenchements multiples pour la même zone de scroll
      const triggerThreshold = 200.0;
      final distanceFromTop = maxExtent - pixels;
      
      if (distanceFromTop <= triggerThreshold) {
        // 🚀 CORRECTION: Éviter les déclenchements trop fréquents en vérifiant la dernière position
        // Si on a déjà déclenché récemment à une position proche, ignorer
        if (_lastScrollTriggerPosition != null) {
          final positionDiff = (pixels - _lastScrollTriggerPosition!).abs();
          // Si on est à moins de 50px de la dernière position de déclenchement, ignorer
          if (positionDiff < 50.0) {
            return false;
          }
        }
        
        debugPrint('🔄 Scroll détecté - Chargement messages anciens... (pixels: $pixels, maxExtent: $maxExtent, distanceFromTop: $distanceFromTop)');
        
        // 🚀 CORRECTION: Bloquer immédiatement la détection pour éviter les déclenchements multiples
        _isScrollDetectionBlocked = true;
        _lastScrollTriggerPosition = pixels;
        
        _loadOlderPreservingOffset();
      }
    }
    return false;
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    // 📊 BENCHMARK: Mesurer le chargement initial complet de l'écran
    final loadTimer = PerformanceBenchmark.instance.startTimer('conversation_screen_load_initial');
    
    try {
      // 🚀 OPTIMISATION: Charger les messages EN PREMIER pour affichage immédiat
      // L'écran est déjà affiché, on charge les messages en arrière-plan
      
      // 1) Charger les messages en premier (peut être depuis le stockage local = instantané)
      // Cette opération notifie automatiquement les listeners quand les messages arrivent
      // IMPORTANT: fetchMessages attend maintenant la synchronisation serveur pour inclure le dernier message
      await _conversationProvider.fetchMessages(
        context, 
        widget.conversationId,
        limit: _messagesPerPage,  // Limiter à 25 messages au lieu de TOUT charger
      );
      
      // 2) Les messages sont maintenant dans le provider et s'affichent automatiquement
      // via le watch() dans le build()
      if (!mounted) return;
      setState(() => _isLoading = false);
      
      // Initialiser le compteur de messages pour détecter les nouveaux
      final initialMessages = _conversationProvider.messagesFor(widget.conversationId);
      _lastMessageCount = initialMessages.length;
      
      // 📊 BENCHMARK: Mesurer le déchiffrement progressif
      final decryptTimer = PerformanceBenchmark.instance.startTimer('conversation_screen_decrypt_initial');
      
      // 3) Déchiffrement progressif - maintenant que tous les messages sont chargés (y compris le dernier)
      // CORRECTION: Attendre un petit délai pour s'assurer que tous les messages sont bien dans la liste
      await Future.delayed(const Duration(milliseconds: 100));
      _startProgressiveDecryption();
      
      // Attendre que les 5 premiers messages visibles soient déchiffrés
      await Future.delayed(const Duration(milliseconds: 500));
      PerformanceBenchmark.instance.stopTimer(decryptTimer);
      
      PerformanceBenchmark.instance.stopTimer(loadTimer);
      
      // 📊 Afficher le rapport après chargement initial
      Future.delayed(const Duration(seconds: 2), () {
        PerformanceBenchmark.instance.printReport();
      });
      
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

  /// 🚀 OPTIMISATION: Déchiffrement UNIQUEMENT des messages visibles à l'écran
  /// - Messages visibles déchiffrés SÉQUENTIELLEMENT dans l'ordre (du plus récent au plus ancien)
  /// - Aucun déchiffrement en arrière-plan pour économiser les ressources
  /// - Focus sur les 10-15 derniers messages (ceux visibles à l'arrivée sur la conversation)
  void _startProgressiveDecryption() {
    final messages = _conversationProvider.messagesFor(widget.conversationId);
    if (messages.isEmpty) return;
    
    // 🚀 PRIORITÉ: Déchiffrer uniquement les 10-15 derniers messages (visibles à l'écran)
    // Ces messages sont ceux qui apparaissent quand on arrive sur la conversation
    // On ne déchiffre PAS les messages plus anciens pour économiser les ressources
    const visibleCount = 12; // Nombre de messages visibles à déchiffrer (couvre ~1 écran)
    final visibleMessages = messages.length > visibleCount 
        ? messages.sublist(messages.length - visibleCount)
        : messages;
    
    // 🚀 OPTIMISATION: Déchiffrer séquentiellement dans l'ordre (du plus récent au plus ancien)
    // Inverser pour commencer par le plus récent
    final orderedVisibleMessages = visibleMessages.reversed.toList();
    
    // Déchiffrer uniquement les messages visibles - pas de déchiffrement en arrière-plan
    _decryptVisibleMessagesSequentially(orderedVisibleMessages);
  }
  
  /// Déchiffre les nouveaux messages qui arrivent après le chargement initial
  /// Appelé quand de nouveaux messages sont ajoutés à la conversation
  void _decryptNewMessages(List<Message> newMessages) {
    if (newMessages.isEmpty || !mounted) return;
    
    // Déchiffrer uniquement les messages qui ne sont pas encore déchiffrés
    final toDecrypt = newMessages.where((msg) => 
      msg.decryptedText == null && msg.v2Data != null
    ).toList();
    
    if (toDecrypt.isEmpty) return;
    
    debugPrint('🔐 [NewMessages] Déchiffrement de ${toDecrypt.length} nouveaux messages');
    
    // Déchiffrer séquentiellement avec haute priorité
    _decryptVisibleMessagesSequentially(toDecrypt.reversed.toList());
  }
  
  /// Déchiffre les messages visibles séquentiellement dans l'ordre pour une meilleure UX
  /// Les messages apparaissent dans l'ordre d'affichage (du plus récent au plus ancien)
  Future<void> _decryptVisibleMessagesSequentially(List<Message> messages) async {
    debugPrint('🔐 [Visible] Début déchiffrement séquentiel de ${messages.length} messages visibles');
    
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (!mounted) break;
      
      // Déchiffrer si pas encore déchiffré OU si signature pas vérifiée
      if ((msg.decryptedText == null || msg.signatureValid != true) && msg.v2Data != null) {
        try {
          debugPrint('🔐 [Visible] Déchiffrement séquentiel message ${i + 1}/${messages.length}: ${msg.id}');
          
          // Déchiffrer séquentiellement avec haute priorité - chaque message attend le précédent
          await _decryptMessageUltraFluid(msg, isVisible: true);
          
          debugPrint('✅ [Visible] Message ${i + 1}/${messages.length} déchiffré: ${msg.id}');
          
          // Petit délai pour laisser l'UI se mettre à jour
          await Future.delayed(const Duration(milliseconds: 10));
        } catch (e) {
          debugPrint('⚠️ Erreur déchiffrement visible ${msg.id}: $e');
          // Continuer avec le message suivant même en cas d'erreur
        }
      } else {
        debugPrint('⏭️ [Visible] Message ${i + 1}/${messages.length} déjà déchiffré: ${msg.id}');
      }
    }
    
    debugPrint('✅ [Visible] Tous les messages visibles déchiffrés');
    
    if (mounted) {
      _messageUpdateNotifier.value = 'batch_visible_done';
    }
  }
  
  /// 🚀 OPTIMISATION: Déchiffrement "on-demand" lors du scroll vers le haut
  /// Déchiffre uniquement les messages qui deviennent visibles lors du scroll
  /// (limité à 5 messages à la fois pour ne pas surcharger)
  void _decryptOnScroll(List<Message> messages, int startIndex) {
    if (!mounted) return;
    
    // Déchiffrer seulement les 5 messages les plus proches qui ne sont pas encore déchiffrés
    const onScrollDecryptCount = 5;
    final endIndex = (startIndex + onScrollDecryptCount).clamp(0, messages.length);
    final messagesToDecrypt = messages.sublist(startIndex, endIndex);
    
    debugPrint('🔐 [OnScroll] Déchiffrement on-demand de ${messagesToDecrypt.length} messages (index $startIndex-$endIndex)');
    
    // Déchiffrer en parallèle (mais limité à 5) pour ne pas bloquer
    final futures = <Future<void>>[];
    for (final msg in messagesToDecrypt) {
      if ((msg.decryptedText == null || msg.signatureValid != true) && msg.v2Data != null) {
        final future = _decryptMessageUltraFluid(msg, isVisible: false).catchError((e) {
          debugPrint('⚠️ Erreur déchiffrement on-scroll ${msg.id}: $e');
        });
        futures.add(future);
      }
    }
    
    Future.wait(futures).then((_) {
      if (mounted) {
        _messageUpdateNotifier.value = 'on_scroll_decrypt';
      }
    });
  }
  
  /// 🚀 OPTIMISATION: Déchiffrement en arrière-plan de tous les nouveaux messages
  /// Déchiffre tous les nouveaux messages chargés lors de la pagination
  /// Cela améliore la réactivité car les messages sont prêts quand l'utilisateur scroll vers eux
  void _decryptNewMessagesInBackground(List<Message> messages, int startIndex, int count) {
    if (!mounted) return;
    
    final endIndex = (startIndex + count).clamp(0, messages.length);
    final messagesToDecrypt = messages.sublist(startIndex, endIndex);
    
    debugPrint('🔐 [Background] Déchiffrement en arrière-plan de ${messagesToDecrypt.length} messages (index $startIndex-$endIndex)');
    
    // Déchiffrer en parallèle tous les nouveaux messages (en arrière-plan, priorité basse)
    final futures = <Future<void>>[];
    for (final msg in messagesToDecrypt) {
      if ((msg.decryptedText == null || msg.signatureValid != true) && msg.v2Data != null) {
        final future = _decryptMessageUltraFluid(msg, isVisible: false).catchError((e) {
          debugPrint('⚠️ Erreur déchiffrement background ${msg.id}: $e');
        });
        futures.add(future);
      }
    }
    
    Future.wait(futures).then((_) {
      if (mounted) {
        _messageUpdateNotifier.value = 'background_decrypt_done';
        debugPrint('✅ [Background] Déchiffrement en arrière-plan terminé pour ${messagesToDecrypt.length} messages');
      }
    });
  }
  
  /// 🚀 OPTIMISATION: Déchiffrement rapide puis vérification de signature en arrière-plan
  /// - Déchiffre rapidement d'abord (decryptFast) pour affichage immédiat
  /// - Vérifie la signature ensuite (decrypt) en arrière-plan
  /// [isVisible] : true pour les messages visibles (haute priorité dans l'Isolate)
  Future<void> _decryptMessageUltraFluid(Message message, {bool isVisible = false}) async {
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
        // 🚀 OPTIMISATION: Utiliser haute priorité pour les messages visibles
        final fastResult = await MessageCipherV2.decryptFast(
          groupId: groupId,
          myUserId: currentUserId,
          myDeviceId: myDeviceId,
          messageV2: message.v2Data!,
          keyDirectory: _conversationProvider.keyDirectory,
          priority: isVisible ? 1 : 0, // Haute priorité pour les messages visibles
        );
        
        final decryptedText = utf8.decode(fastResult['decryptedText'] as Uint8List);
        message.decryptedText = decryptedText;
        message.signatureValid = false; // Temporairement non vérifié
        
        // Mise à jour UI immédiate
        if (mounted) {
          // Notifier le ValueListenableBuilder pour mise à jour granulaire
          _messageUpdateNotifier.value = message.id;
        }
      }
      
      // 🚀 ÉTAPE 2: Vérification de signature
      // CORRECTION: Pour les messages visibles, attendre la vérification pour garantir l'ordre
      // Pour les messages en arrière-plan, vérifier en non-bloquant
      // ⚠️ IMPORTANT: Ne pas appeler decryptMessageIfNeeded pour les messages visibles
      // car cela déclenche des appels parallèles via MessageKeyCache qui perturbent l'ordre
      // La vérification de signature sera faite en arrière-plan après le déchiffrement initial
      if (message.signatureValid != true) {
        if (isVisible) {
          // Pour les messages visibles : vérifier en arrière-plan (non-bloquant)
          // pour ne pas perturber l'ordre séquentiel du déchiffrement initial
          _conversationProvider.decryptMessageIfNeeded(message).then((_) {
            Future.delayed(Duration(milliseconds: 50), () {
              if (mounted) {
                _messageUpdateNotifier.value = message.id;
              }
            });
          }).catchError((e) {
            debugPrint('⚠️ Erreur vérification signature message ${message.id}: $e');
          });
        } else {
          // Pour les messages en arrière-plan : vérifier en non-bloquant
          _conversationProvider.decryptMessageIfNeeded(message).then((_) {
            Future.delayed(Duration(milliseconds: 50), () {
              if (mounted) {
                _messageUpdateNotifier.value = message.id;
              }
            });
          }).catchError((e) {
            debugPrint('⚠️ Erreur vérification signature message ${message.id}: $e');
          });
        }
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

  /// Ajuste la position de scroll après ajout de messages (reverse:true)
  /// CORRECTION: Attend que l'utilisateur arrête de scroller avant d'ajuster pour éviter les conflits
  void _adjustScrollPosition(double beforeMaxExtent, List<Message> currentMessages) {
    if (!_scrollController.hasClients || !mounted) {
      // 🚀 CORRECTION: Débloquer la détection si le scroll controller n'est plus disponible
      _isScrollDetectionBlocked = false;
      return;
    }
    
    // CORRECTION: Capturer l'offset ACTUEL juste avant l'ajustement
    // Pas celui capturé au début du chargement, car l'utilisateur a pu continuer à scroller
    final currentOffset = _scrollController.offset;
    final afterMaxExtent = _scrollController.position.maxScrollExtent;
    final extentDiff = afterMaxExtent - beforeMaxExtent;
    
    debugPrint('📍 Ajustement scroll - Offset actuel: $currentOffset, MaxExtent avant: $beforeMaxExtent, MaxExtent après: $afterMaxExtent, Différence: $extentDiff');
    
    // CORRECTION: Vérifier si l'utilisateur est en train de scroller activement
    // Si oui, attendre qu'il arrête avant d'ajuster pour éviter les conflits
    final isScrolling = _scrollController.position.isScrollingNotifier.value;
    
    if (isScrolling) {
      debugPrint('⏸️ Utilisateur en train de scroller, attente de la fin du scroll...');
      // Attendre que l'utilisateur arrête de scroller
      if (!_isListeningToScroll) {
        _scrollController.position.isScrollingNotifier.addListener(_onScrollingStateChanged);
        _isListeningToScroll = true;
      }
      // Stocker les valeurs pour l'ajustement différé
      _pendingScrollAdjustment = () {
        _adjustScrollPosition(beforeMaxExtent, currentMessages);
      };
      return;
    }
    
    // CORRECTION: Avec reverse:true, pour préserver la position visuelle,
    // on doit augmenter l'offset de la différence de hauteur
    // Utiliser jumpTo pour un ajustement immédiat sans animation qui pourrait perturber
    if (extentDiff > 0) {
      final newOffset = currentOffset + extentDiff;
      _scrollController.jumpTo(newOffset.clamp(0.0, afterMaxExtent));
      debugPrint('✅ Position scroll ajustée: $newOffset');
    }
    
    // 🚀 OPTIMISATION: Déchiffrer "on-demand" les messages qui viennent d'être chargés
    // (seulement les 5 premiers pour ne pas surcharger)
    final finalMessages = _conversationProvider.messagesFor(widget.conversationId);
    if (finalMessages.length > currentMessages.length) {
      final newStartIndex = currentMessages.length;
      _decryptOnScroll(finalMessages, newStartIndex);
    }
  }
  
  // Callback pour l'ajustement différé quand l'utilisateur arrête de scroller
  VoidCallback? _pendingScrollAdjustment;
  bool _isListeningToScroll = false;
  
  void _onScrollingStateChanged() {
    if (!_scrollController.hasClients || !mounted) {
      _removeScrollListener();
      // 🚀 CORRECTION: Débloquer la détection si le scroll controller n'est plus disponible
      _isScrollDetectionBlocked = false;
      return;
    }
    
    // Si l'utilisateur a arrêté de scroller et qu'on a un ajustement en attente
    if (!_scrollController.position.isScrollingNotifier.value && _pendingScrollAdjustment != null) {
      _removeScrollListener();
      final adjustment = _pendingScrollAdjustment;
      _pendingScrollAdjustment = null;
      
      // Attendre un court délai pour être sûr que le scroll est vraiment terminé
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && adjustment != null) {
          adjustment();
          // 🚀 CORRECTION: Débloquer la détection après l'ajustement différé
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) {
              _isScrollDetectionBlocked = false;
              _lastScrollTriggerPosition = null;
            }
          });
        }
      });
    }
  }
  
  void _removeScrollListener() {
    if (_isListeningToScroll && _scrollController.hasClients) {
      _scrollController.position.isScrollingNotifier.removeListener(_onScrollingStateChanged);
      _isListeningToScroll = false;
    }
  }

  /// Charge les messages plus anciens en préservant la position de scroll (reverse:true)
  Future<void> _loadOlderPreservingOffset() async {
    if (_isLoading || !_hasMoreOlderMessages) {
      debugPrint('⏸️ Chargement ignoré - isLoading: $_isLoading, hasMore: $_hasMoreOlderMessages');
      // 🚀 CORRECTION: Débloquer la détection même si on ignore le chargement
      _isScrollDetectionBlocked = false;
      return;
    }
    
    if (!_scrollController.hasClients) {
      debugPrint('⏸️ ScrollController non disponible');
      _isScrollDetectionBlocked = false;
      return;
    }
    
    // CORRECTION: Capturer seulement maxScrollExtent au début
    // L'offset actuel sera capturé juste avant l'ajustement pour tenir compte du scroll continu de l'utilisateur
    final beforeMaxExtent = _scrollController.position.maxScrollExtent;
    final currentMessages = _conversationProvider.messagesFor(widget.conversationId);
    debugPrint('🔄 Début chargement - Messages actuels: ${currentMessages.length}, MaxExtent: $beforeMaxExtent');
    
    // 📊 BENCHMARK: Mesurer la pagination complète (scroll)
    final scrollTimer = PerformanceBenchmark.instance.startTimer('conversation_screen_scroll_pagination');
    
    // CORRECTION: Démarrer l'indicateur de chargement immédiatement
    setState(() => _isLoading = true);
    
    // CORRECTION: Délai minimum pour que l'indicateur soit visible (800ms)
    // Cela permet à l'utilisateur de comprendre ce qui se passe
    final minimumDisplayTime = Future.delayed(const Duration(milliseconds: 800));
    
    try {
      // Charger les messages depuis le serveur
      final hasMore = await _conversationProvider.fetchOlderMessages(
        context,
        widget.conversationId,
        limit: _messagesPerPage,
      );
      
      final newMessages = _conversationProvider.messagesFor(widget.conversationId);
      debugPrint('📄 Chargement terminé - Nouveaux messages: ${newMessages.length - currentMessages.length}, hasMore: $hasMore');
      
      // 🚀 OPTIMISATION: Démarrer le déchiffrement en parallèle même si les messages ne sont pas encore visibles
      // Cela améliore la réactivité globale - déchiffrer tous les nouveaux messages
      if (newMessages.length > currentMessages.length) {
        final newStartIndex = currentMessages.length;
        final newMessagesCount = newMessages.length - currentMessages.length;
        // Déchiffrer tous les nouveaux messages en arrière-plan sans attendre
        // Utiliser une version étendue qui déchiffre tous les messages, pas seulement 5
        _decryptNewMessagesInBackground(newMessages, newStartIndex, newMessagesCount);
      }
      
      // Arrêter le chargement s'il n'y a plus de messages
      if (!hasMore) {
        _hasMoreOlderMessages = false;
        debugPrint('📄 Plus de messages anciens à charger');
      }
      
      // Attendre le délai minimum ET la fin du chargement
      await minimumDisplayTime;
      
      PerformanceBenchmark.instance.stopTimer(scrollTimer);
      
      // CORRECTION: Préserver la position de scroll avec reverse:true
      // Avec reverse:true, quand on ajoute des messages en haut, maxScrollExtent augmente
      // Il faut ajuster l'offset pour compenser cette augmentation
      // Utiliser plusieurs callbacks pour s'assurer que le layout est terminé
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Attendre un frame supplémentaire pour que le layout soit stable
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Attendre encore un frame pour être sûr que le layout est complètement terminé
          // Cela évite les sauts brusques lors de l'ajustement
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients || !mounted) {
              // 🚀 CORRECTION: Débloquer la détection même si le scroll controller n'est plus disponible
              _isScrollDetectionBlocked = false;
              return;
            }
            _adjustScrollPosition(beforeMaxExtent, currentMessages);
            
            // 🚀 CORRECTION: Débloquer la détection de scroll après l'ajustement
            // Ajouter un petit délai pour éviter les déclenchements immédiats après l'ajustement
            Future.delayed(const Duration(milliseconds: 300), () {
              if (mounted) {
                _isScrollDetectionBlocked = false;
                _lastScrollTriggerPosition = null; // Réinitialiser pour permettre un nouveau déclenchement
                debugPrint('✅ Détection de scroll débloquée après chargement');
              }
            });
          });
        });
      });
    } catch (e) {
      debugPrint('❌ Erreur chargement messages anciens: $e');
      // Attendre quand même le délai minimum même en cas d'erreur
      await minimumDisplayTime;
      // 🚀 CORRECTION: Débloquer la détection en cas d'erreur
      _isScrollDetectionBlocked = false;
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  int _lastMessageCount = 0;

  void _onMessagesUpdated() {
    // 🚀 CORRECTION: Toujours permettre les mises à jour pour les nouveaux messages WebSocket
    // Même si le déchiffrement initial n'est pas terminé, les nouveaux messages doivent s'afficher
    
    final currentMessages = _conversationProvider.messagesFor(widget.conversationId);
    final currentCount = currentMessages.length;
    
    // Détecter les nouveaux messages
    if (currentCount > _lastMessageCount && _lastMessageCount > 0) {
      final newMessages = currentMessages.sublist(_lastMessageCount);
      debugPrint('🔐 [NewMessages] ${newMessages.length} nouveaux messages détectés');
      _decryptNewMessages(newMessages);
    }
    _lastMessageCount = currentCount;
    
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
    debugPrint('📤 [ConversationScreen] Bouton d\'envoi pressé, texte: ${plainText.length > 50 ? plainText.substring(0, 50) + "..." : plainText}');
    
    if (plainText.isEmpty) {
      debugPrint('⚠️ [ConversationScreen] Texte vide, envoi annulé');
      return;
    }
    
    // Arrêter l'indicateur de frappe avant d'envoyer
    _conversationProvider.stopTyping(widget.conversationId);
    _typingTimer?.cancel();
    
    // 🚀 OPTIMISATION: Vider le champ immédiatement pour feedback UI instantané
    _textController.clear();
    
    debugPrint('📤 [ConversationScreen] Appel de sendMessage pour conversation ${widget.conversationId}');
    
    // 🚀 OPTIMISATION: Envoyer en arrière-plan sans bloquer l'UI
    // Le déchiffrement peut continuer en parallèle
    _conversationProvider.sendMessage(context, widget.conversationId, plainText).catchError((e) {
      // En cas d'erreur, restaurer le texte pour que l'utilisateur puisse réessayer
      if (mounted) {
        _textController.text = plainText;
        debugPrint('❌ [ConversationScreen] Erreur envoi message: $e');
        debugPrint('❌ [ConversationScreen] Stack trace: ${StackTrace.current}');
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
    // Désenregistrer la conversation
    NavigationTrackerService().setConversationClosed(widget.conversationId);
    
    // SÉCURITÉ: Ne pas se désabonner quand on quitte la conversation
    // L'abonnement est géré automatiquement par fetchConversations()
    // et reste actif pour recevoir les notifications même quand on n'est pas sur l'écran
    // Le backend vérifie les permissions avant d'envoyer les messages
    
    _conversationProvider.removeListener(_onMessagesUpdated);
    // Nettoyer le listener de scroll si présent
    _removeScrollListener();
    _textController.dispose();
    _scrollController.dispose();
    _messageUpdateNotifier.dispose(); // Nettoyer le ValueNotifier
    _typingTimer?.cancel(); // Annuler le timer de frappe
    _pendingScrollAdjustment = null; // Nettoyer l'ajustement en attente
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
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Chargement...',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : messages.isEmpty && !_isLoading
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(48.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline,
                                  size: 64,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.4),
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  'Aucun message pour le moment',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Commencez la conversation !',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Stack(
                      children: [
                        ListView.builder(
                          reverse: true, // Clé anti-jump
                          controller: _scrollController,
                          itemCount: messages.length,
                          itemBuilder: (_, i) {
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
                                // Indicateur de date avec design professionnel
                                if (showDateHeader)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          dateOnly.toChatDateHeader(),
                                          style: TextStyle(
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: 0.3,
                                          ),
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
                        // Indicateur de chargement fixe en haut de l'écran avec design professionnel
                        if (_isLoading)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 20.0),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Theme.of(context).colorScheme.surface,
                                    Theme.of(context).colorScheme.surface.withOpacity(0.0),
                                  ],
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),

          // Zone de saisie avec SafeArea pour Android - Design professionnel
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Indicateur de frappe
                  _buildTypingIndicator(),
                  
                  // Zone de saisie avec design amélioré
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.03),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: _textController,
                            onChanged: _onTextChanged,
                            decoration: InputDecoration(
                              hintText: 'Tapez votre message...',
                              hintStyle: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              filled: false,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            maxLines: 4,
                            minLines: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: FloatingActionButton(
                          onPressed: _onSendPressed,
                          mini: true,
                          elevation: 0,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          child: const Icon(Icons.send, size: 20),
                        ),
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

/// Widget pour afficher le statut de connexion WebSocket avec heartbeat
class _WebSocketStatusIndicator extends StatefulWidget {
  @override
  State<_WebSocketStatusIndicator> createState() => _WebSocketStatusIndicatorState();
}

class _WebSocketStatusIndicatorState extends State<_WebSocketStatusIndicator> {
  StreamSubscription<SocketStatus>? _wsStatusSubscription;
  StreamSubscription<HeartbeatState>? _heartbeatSubscription;
  SocketStatus _wsStatus = SocketStatus.disconnected;
  HeartbeatState? _heartbeatState;
  bool _hasNetwork = true;

  @override
  void initState() {
    super.initState();
    
    // Écouter le statut WebSocket
    _wsStatusSubscription = WebSocketService.instance.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _wsStatus = status;
        });
      }
    });
    
    // Écouter l'état du heartbeat
    final heartbeatService = WebSocketHeartbeatService();
    _heartbeatSubscription = heartbeatService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _heartbeatState = state;
        });
      }
    });
    
    // Écouter l'état du réseau
    NetworkMonitorService().networkStatusStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          _hasNetwork = isConnected;
        });
      }
    });
    
    // Initialiser les valeurs
    _wsStatus = WebSocketService.instance.status;
    _heartbeatState = heartbeatService.currentState;
    _hasNetwork = NetworkMonitorService().isConnected;
  }

  @override
  void dispose() {
    _wsStatusSubscription?.cancel();
    _heartbeatSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heartbeatService = WebSocketHeartbeatService();
    final isHealthy = _heartbeatState?.isConnectionHealthy ?? heartbeatService.isConnectionHealthy;
    
    // Déterminer la couleur selon l'état
    Color statusColor;
    String tooltip;
    
    if (!_hasNetwork) {
      statusColor = Colors.grey;
      tooltip = 'Pas de connexion réseau';
    } else if (_wsStatus == SocketStatus.connected) {
      if (isHealthy) {
        statusColor = Colors.green;
        tooltip = 'Connecté au serveur';
      } else {
        statusColor = Colors.orange;
        tooltip = 'Connexion instable';
      }
    } else if (_wsStatus == SocketStatus.connecting) {
      statusColor = Colors.orange;
      tooltip = 'Connexion en cours...';
    } else {
      statusColor = Colors.red;
      tooltip = 'Déconnecté';
    }
    
    return Tooltip(
      message: tooltip,
      child: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
          color: statusColor,
        shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: statusColor.withOpacity(0.5),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}
