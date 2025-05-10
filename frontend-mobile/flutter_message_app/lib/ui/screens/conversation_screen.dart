import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;
import 'package:provider/provider.dart';
import '../../core/crypto/encryption_utils.dart';
import '../../core/services/websocket_service.dart';
import '../../core/crypto/key_manager.dart';

class ConversationScreen extends StatefulWidget {
  final String conversationId;
  final String groupId;

  const ConversationScreen({super.key, required this.conversationId, required this.groupId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  List<Map<String, dynamic>> _rawMessages = [];
  Map<String, String> _decryptedMessages = {};
  Map<String, bool> _verifiedSignatures = {};

  bool _loading = true;
  bool _sending = false;
  String? _currentUserId;
  Uint8List? _aesConversationKey;

  // Ajout : mapping userId → username pour le groupe courant
  Map<String, String> _usernamesById = {};

  // Ajout : mapping userId → publicKey pour la conversation
  Map<String, String> _userPublicKeys = {};

  // Pagination
  static const int _pageSize = 20;
  int _currentPage = 0;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  // Scroll/UX
  bool _showNewMessageButton = false;
  bool _userIsAtBottom = true;

  final int _initialDecryptCount = 20;
  final String _listenerId = 'conversation_screen';

  @override
  void initState() {
    super.initState();
    WebSocketService.instance.screenAttached();
    _initializeConversation();
    _scrollController.addListener(_onScroll);
    _fetchGroupMembers();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    WebSocketService.instance.removeOnNewMessageListener(_listenerId);
    WebSocketService.instance.screenDetached();
    super.dispose();
  }

  String _generateMessageId(Map<String, dynamic> msg, int index) {
    return msg['id'] ?? '${msg['senderId']}_${msg['timestamp'] ?? index}_${msg['encrypted'] ?? ''}_${msg['iv'] ?? ''}';
  }

  Future<void> _initializeConversation() async {
    await _loadCurrentUserId();
    await _loadConversationSecret();

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tokenValid = await auth.ensureTokenValid();
    if (!tokenValid) {
      _showError('Session expirée, veuillez vous reconnecter');
      return;
    }
    final token = auth.token;
    if (token == null) { _showError('Token JWT manquant'); return; }

    WebSocketService.instance.connect(context, conversationId: widget.conversationId);
    WebSocketService.instance.subscribeConversation(widget.conversationId);

    WebSocketService.instance.setOnNewMessageListener(
      _listenerId,
      (message) async {
        if (!mounted) return;
        final messageId = _generateMessageId(message, _rawMessages.length);
        final alreadyExists = _rawMessages.any((m) =>
          _generateMessageId(m, _rawMessages.indexOf(m)) == messageId
        );
        if (!alreadyExists) {
          setState(() {
            _rawMessages.insert(0, message);
          });
          await _decryptVisibleMessages();
          if (_userIsAtBottom) _scrollToBottom();
        }
      },
    );

    WebSocketService.instance.statusStream.listen((status) {
      if (status == SocketStatus.error) {
        _showError('Erreur WebSocket');
        _attemptReconnect();
      }
    });
    await _loadMessages();
    setState(() => _loading = false);
  }

  Future<void> _loadCurrentUserId() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tokenValid = await auth.ensureTokenValid();
    if (!tokenValid) {
      _showError('Session expirée, veuillez vous reconnecter');
      return;
    }
    final token = auth.token;
    if (token == null) { _showError('Token JWT manquant'); return; }

    final resUser = await http.get(
      Uri.parse('https://auth.kavalek.fr/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (resUser.statusCode == 200) {
      final data = jsonDecode(resUser.body);
      _currentUserId = data['user']['id'];
    } else {
      _showError('Erreur chargement userId: ${resUser.body}');
    }
  }

  Future<void> _loadConversationSecret() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tokenValid = await auth.ensureTokenValid();
    if (!tokenValid) {
      _showError('Session expirée, veuillez vous reconnecter');
      return;
    }
    final token = auth.token;
    if (token == null) { _showError('Token JWT manquant'); return; }

    try {
      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode != 200) {
        _showError('Impossible de récupérer les informations de la conversation.');
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final secrets = data['encrypted_secrets'] as Map<String, dynamic>;
      final encryptedSecretBase64 = secrets[_currentUserId];
      if (encryptedSecretBase64 == null) {
        _showError('Vous n\'avez pas (ou plus) accès à cette conversation. Les anciens messages ne sont pas disponibles.');
        return;
      }

      // On tente de déchiffrer en RSA‐OAEP
      final keyPair = await KeyManager().getKeyPairForGroup(widget.groupId);
      if (keyPair == null) {
        _showError('Clé privée du groupe introuvable. Veuillez recréer une conversation.');
        return;
      }

      final privateKey = keyPair.privateKey as pc.RSAPrivateKey;
      final cipher = pc.OAEPEncoding(pc.RSAEngine())
        ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));

      _aesConversationKey = cipher.process(base64.decode(encryptedSecretBase64));
      debugPrint('🧬 Clé AES chargée: ${base64.encode(_aesConversationKey!)}');
    } on FormatException {
      // Erreur de base64.decode ou JSON
      _showError(
        'Impossible de lire la clé de chiffrement.\n'
        'Si vous venez de mettre à jour votre clé de groupe, créez une nouvelle conversation pour obtenir un nouveau secret.'
      );
    } catch (e) {
      // Toute autre erreur
      _showError(
        'Impossible de lire la clé de chiffrement.\n'
        'Si vous venez de mettre à jour votre clé de groupe, créez une nouvelle conversation pour obtenir un nouveau secret.'
      );
    }
  }

  Future<void> _loadMessages({bool append = false}) async {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final token = auth.token;
      if (token == null) {
        _showError('Token JWT manquant');
        return;
      }
      final offset = _currentPage * _pageSize;
      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}/messages?offset=$offset&limit=$_pageSize'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final messages = List<Map<String, dynamic>>.from(data);
        setState(() {
          if (append) {
            _rawMessages.addAll(messages.reversed);
          } else {
            _rawMessages = messages.reversed.toList();
          }
          _hasMore = messages.length == _pageSize;
          if (_hasMore) _currentPage++;
        });
        // Pré-remplir _verifiedSignatures si signatureValid est présent
        for (int i = 0; i < _rawMessages.length; i++) {
          final m = _rawMessages[i];
          final messageId = _generateMessageId(m, i);
          if (m.containsKey('signatureValid')) {
            _verifiedSignatures[messageId] = m['signatureValid'] == true;
          }
        }
        await _decryptVisibleMessages();
      } else {
        _showError('Erreur chargement messages: ${res.body}');
      }
    } catch (e) {
      _showError('Erreur réseau');
    } finally {
      setState(() {
        _loading = false;
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _decryptVisibleMessages({int? start, int? end}) async {
    if (_aesConversationKey == null) return;
    final s = start ?? 0;
    final e = end ?? (_rawMessages.length < _initialDecryptCount ? _rawMessages.length : _initialDecryptCount);
    for (int i = s; i < e; i++) {
      final m = _rawMessages[i];
      final messageId = _generateMessageId(m, i);
      if (_decryptedMessages.containsKey(messageId)) continue;
      try {
        final decrypted = await EncryptionUtils.decryptMessageTaskSimple({
          'encrypted': m['encrypted'],
          'iv': m['iv'],
          'aesKey': base64.encode(_aesConversationKey!),
        });
        _decryptedMessages[messageId] = decrypted;
        // Utiliser signatureValid si présent, sinon fallback sur vérification locale
        if (m.containsKey('signatureValid')) {
          _verifiedSignatures[messageId] = m['signatureValid'] == true;
        } else {
          final signedPayload = json.encode({
            'encrypted': m['encrypted'],
            'iv': m['iv'],
          });
          final senderId = m['senderId'];
          final expectedPublicKey = _userPublicKeys[senderId];
          bool valid = false;
          if (expectedPublicKey != null) {
            valid = await EncryptionUtils.verifySignature(
              payload: json.decode(signedPayload),
              signature: m['signature'],
              senderPublicKeyPem: expectedPublicKey,
            );
          }
          _verifiedSignatures[messageId] = valid;
        }
      } catch (e) {
        _decryptedMessages[messageId] = '[Déchiffrement impossible]';
      }
    }
    setState(() {});
  }

  String canonicalJson(Map<String, dynamic> map) {
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final buffer = StringBuffer('{');
    bool first = true;
    for (var entry in sorted.entries) {
      if (!first) buffer.write(',');
      buffer.write('"${entry.key}":"${entry.value}"');
      first = false;
    }
    buffer.write('}');
    return buffer.toString();
  }

  Future<void> _sendMessage() async {
    if (_sending || _aesConversationKey == null) return;

    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    _messageController.clear();

    try {
      final encrypted = await EncryptionUtils.encryptWithAESKey(
        plaintext: text,
        aesKey: _aesConversationKey!,
      );

      final payloadToSign = canonicalJson({
        'encrypted': encrypted['encrypted'],
        'iv': encrypted['iv'],
      });

      final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
      if (keyPair == null) {
        _showError('Clé privée RSA manquante pour signer le message');
        return;
      }

      final signer = pc.Signer('SHA-256/RSA')
        ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(
          keyPair.privateKey as pc.RSAPrivateKey,
        ));

      final signature = signer.generateSignature(
        Uint8List.fromList(utf8.encode(payloadToSign)),
      ) as pc.RSASignature;

      final signatureBase64 = base64.encode(signature.bytes);
      final publicKeyPem = encodePublicKeyToPem(
        keyPair.publicKey as pc.RSAPublicKey,
      );

      // On crée un JSON “envelope” complet
      final envelope = {
        'encrypted':       encrypted['encrypted'],
        'iv':              encrypted['iv'],
        'signature':       signatureBase64,
        'senderPublicKey': publicKeyPem,
      };

      WebSocketService.instance.sendMessage({
        'conversationId':    widget.conversationId,
        'encrypted_message': jsonEncode(envelope),
        'encrypted_keys':    {}, 
      });
    } catch (e) {
      _showError('Erreur envoi message');
    } finally {
      setState(() => _sending = false);
    }
  }

  void _onScroll() async {
    if (!_scrollController.hasClients) return;
    // Pagination: si on est en haut, charge plus
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 50 && _hasMore && !_isLoadingMore) {
      await _loadMessages(append: true);
    }
    // Scroll auto & bouton nouveau message
    final atBottom = _scrollController.position.pixels <= 50;
    if (_userIsAtBottom != atBottom) {
      setState(() => _userIsAtBottom = atBottom);
    }
    if (_userIsAtBottom && _showNewMessageButton) {
      setState(() => _showNewMessageButton = false);
    }
    // Déchiffrement dynamique (inchangé)
    final itemHeight = 56.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final scrollOffset = _scrollController.offset;
    final firstIndex = (_rawMessages.length - 1) - (scrollOffset / itemHeight).floor();
    final visibleCount = (viewportHeight / itemHeight).ceil();
    final lastIndex = (firstIndex - visibleCount + 1).clamp(0, _rawMessages.length - 1);
    final start = lastIndex;
    final end = firstIndex + 1;
    await _decryptVisibleMessages(start: start, end: end);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  Future<void> _attemptReconnect() async {
    // Vérifie et rafraîchit le token si besoin
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final valid = await auth.ensureTokenValid();
    if (!valid) {
      _showError('Session expirée, impossible de se reconnecter');
      return;
    }
    // Réinitialise et reconnecte
    WebSocketService.instance.disconnect();
    WebSocketService.instance.connect(
      context,
      conversationId: widget.conversationId,
    );
    WebSocketService.instance.subscribeConversation(widget.conversationId);
    WebSocketService.instance.setOnNewMessageListener(
      _listenerId,
      (message) async {
        if (!mounted) return;
        final messageId = _generateMessageId(message, _rawMessages.length);
        final exists = _rawMessages.any((m) => _generateMessageId(m, _rawMessages.indexOf(m)) == messageId);
        if (!exists) {
          setState(() => _rawMessages.insert(0, message));
          await _decryptVisibleMessages();
          if (_userIsAtBottom) _scrollToBottom();
        }
      },
    );
  }

  // récupération des membres du groupe
  Future<void> _fetchGroupMembers() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tokenValid = await auth.ensureTokenValid();
    if (!tokenValid) {
      _showError('Session expirée, veuillez vous reconnecter');
      return;
    }
    final token = auth.token;
    if (token == null) { _showError('Token JWT manquant'); return; }
    try {
      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/groups/${widget.groupId}/members'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final members = List<Map<String, dynamic>>.from(jsonDecode(res.body));
        setState(() {
          _usernamesById = {
            for (final m in members)
              if (m['userId'] != null && m['username'] != null)
                m['userId']: m['username']
          };
          _userPublicKeys = {
            for (final m in members)
              if (m['userId'] != null && m['publicKeyGroup'] != null)
                m['userId']: m['publicKeyGroup']
          };
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final itemHeight = 56.0;
        final viewportHeight = _scrollController.position.viewportDimension;
        final scrollOffset = _scrollController.offset;
        final firstIndex = (_rawMessages.length - 1) - (scrollOffset / itemHeight).floor();
        final visibleCount = (viewportHeight / itemHeight).ceil();
        final lastIndex = (firstIndex - visibleCount + 1).clamp(0, _rawMessages.length - 1);
        final start = lastIndex;
        final end = firstIndex + 1;
        _decryptVisibleMessages(start: start, end: end);
      }
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation')),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollEndNotification) {
                            _onScroll();
                          }
                          return false;
                        },
                        child: ListView.builder(
                          key: ValueKey(_rawMessages.length),
                          controller: _scrollController,
                          reverse: true,
                          itemCount: _rawMessages.length,
                          itemBuilder: (context, index) {
                            final msg = _rawMessages[index];
                            final messageId = _generateMessageId(msg, index);
                            final decrypted = _decryptedMessages[messageId] ?? '[En attente de déchiffrement]';
                            final verified = _verifiedSignatures[messageId];
                            final icon = verified == null
                                ? null
                                : verified
                                    ? const Icon(Icons.verified, color: Colors.green, size: 16)
                                    : const Icon(Icons.warning_amber, color: Colors.redAccent, size: 16);
                            final isMe = msg['senderId'] == _currentUserId;
                            final senderInitial = (msg['senderId'] != null && msg['senderId'].isNotEmpty)
                                ? msg['senderId'][0].toUpperCase()
                                : null;
                            String? time;
                            if (msg['timestamp'] != null) {
                              try {
                                final dt = DateTime.tryParse(msg['timestamp']);
                                if (dt != null) {
                                  time = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
                                }
                              } catch (_) {}
                            }
                            // Ajout : récupération du pseudo
                            final senderUsername = !isMe && msg['senderId'] != null ? _usernamesById[msg['senderId']] : null;
                            return MessageBubble(
                              text: decrypted,
                              isMe: isMe,
                              time: time,
                              senderInitial: isMe ? null : senderInitial,
                              trailingIcon: icon,
                              senderUsername: senderUsername,
                            );
                          },
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: const InputDecoration(hintText: 'Votre message...'),
                      ),
                    ),
                    IconButton(
                      icon: _sending
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send),
                      onPressed: _sending ? null : _sendMessage,
                    ),
                  ],
                ),
              )
            ],
          ),
          if (_showNewMessageButton)
            Positioned(
              bottom: 80,
              right: 16,
              child: FloatingActionButton.extended(
                onPressed: () {
                  _scrollToBottom();
                  setState(() => _showNewMessageButton = false);
                },
                label: const Text('Nouveau message'),
                icon: const Icon(Icons.arrow_downward),
                backgroundColor: Colors.blueAccent,
              ),
            ),
        ],
      ),
    );
  }
}

class MessageBubble extends StatefulWidget {
  final String text;
  final bool isMe;
  final String? time;
  final String? senderInitial;
  final Widget? trailingIcon;
  final String? senderUsername;

  const MessageBubble({
    required this.text,
    required this.isMe,
    this.time,
    this.senderInitial,
    this.trailingIcon,
    this.senderUsername,
    super.key,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _showExplanation = false;
  @override
  Widget build(BuildContext context) {
    IconData? iconData;
    Color iconColor = Colors.grey;
    String explanation = '';
    bool showIcon = true;
    if (widget.trailingIcon is Icon) {
      final icon = widget.trailingIcon as Icon;
      if (icon.icon == Icons.verified) {
        iconData = Icons.verified;
        iconColor = Colors.green;
        explanation = "Signature vérifiée : ce message a bien été signé par l'expéditeur.";
        if (widget.isMe) showIcon = false;
      } else if (icon.icon == Icons.warning_amber) {
        iconData = Icons.warning_amber;
        iconColor = Colors.redAccent;
        explanation = 'Signature non vérifiée : ce message pourrait avoir été altéré.';
      }
    }
    return Row(
      mainAxisAlignment: widget.isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!widget.isMe && widget.senderInitial != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: CircleAvatar(
              radius: 18,
              child: Text(
                (widget.senderUsername != null && widget.senderUsername!.isNotEmpty)
                  ? widget.senderUsername![0].toUpperCase()
                  : widget.senderInitial ?? '',
              ),
            ),
          ),
        Flexible(
          child: Column(
            crossAxisAlignment: widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!widget.isMe && widget.senderUsername != null)
                Transform.translate(
                  offset: const Offset(0, 4),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      widget.senderUsername!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 0),
                decoration: BoxDecoration(
                  color: widget.isMe ? Colors.blueAccent : Colors.grey[800],
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: widget.isMe ? const Radius.circular(16) : const Radius.circular(0),
                    bottomRight: widget.isMe ? const Radius.circular(0) : const Radius.circular(16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.text,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    if (widget.time != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          widget.time!,
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                      ),
                  ],
                ),
              ),
              // Affichage de l'icône de vérification SOUS la bulle
              if (iconData != null && showIcon)
                Padding(
                  padding: const EdgeInsets.only(top: 0, left: 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          setState(() => _showExplanation = !_showExplanation);
                          if (!_showExplanation) return;
                          Future.delayed(const Duration(seconds: 3), () {
                            if (mounted) setState(() => _showExplanation = false);
                          });
                        },
                        child: Icon(
                          iconData,
                          color: iconColor.withOpacity(0.7),
                          size: 14,
                        ),
                      ),
                      if (_showExplanation)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          constraints: const BoxConstraints(maxWidth: 220),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text(
                            explanation,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                            textAlign: TextAlign.left,
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}
