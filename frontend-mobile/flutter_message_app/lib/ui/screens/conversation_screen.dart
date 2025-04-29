import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_message_app/core/providers/auth_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  final int _initialDecryptCount = 20;

  @override
  void initState() {
    super.initState();
    _initializeConversation();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    WebSocketService().disconnect();
    super.dispose();
  }

  String _generateMessageId(Map<String, dynamic> msg, int index) {
    return msg['id'] ?? '${msg['senderId']}_${msg['timestamp'] ?? index}_${msg['encrypted'] ?? ''}_${msg['iv'] ?? ''}';
  }

  Future<void> _initializeConversation() async {
    await _loadCurrentUserId();
    await _loadConversationSecret();
    await _loadMessages();

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) {
      _showError('Token JWT manquant');
      return;
    }
    WebSocketService().connect(token, conversationId: widget.conversationId);
    WebSocketService().subscribeConversation(widget.conversationId);
    WebSocketService().onNewMessage((message) async {
      print('🧾 Nouveau message reçu via WebSocket: $message');
      _rawMessages.insert(0, message);
      await _decryptVisibleMessages();
      if (mounted) setState(() {});
    });
    WebSocketService().onError((errorMessage) {
      _showError('Erreur WebSocket: $errorMessage');
      _attemptReconnect();
    });
  }

  Future<void> _loadCurrentUserId() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token == null) {
      _showError('Token JWT manquant');
      return;
    }

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
    final token = auth.token;
    if (token == null) {
      _showError('Token JWT manquant');
      return;
    }

    try {
      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final secrets = data['encrypted_secrets'];
        final encryptedSecretBase64 = secrets[_currentUserId];
        if (encryptedSecretBase64 == null) {
          _showError('Secret AES non disponible pour cet utilisateur.');
          return;
        }

        final keyPair = await KeyManager().getKeyPairForGroup('user_rsa');
        if (keyPair == null) {
          _showError('Clé RSA utilisateur absente');
          return;
        }

        final privateKey = keyPair.privateKey as pc.RSAPrivateKey;
        final cipher = pc.OAEPEncoding(pc.RSAEngine())
          ..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey));

        _aesConversationKey = cipher.process(base64.decode(encryptedSecretBase64));
        print('🧬 _aesConversationKey = ${base64.encode(_aesConversationKey!)}');
      } else {
        _showError('Erreur chargement secret: ${res.body}');
      }
    } catch (e) {
      _showError('Erreur parsing secret: $e');
    }
  }

  Future<void> _loadMessages() async {
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final token = auth.token;
      if (token == null) {
        _showError('Token JWT manquant');
        return;
      }

      final res = await http.get(
        Uri.parse('https://api.kavalek.fr/api/conversations/${widget.conversationId}/messages'),
        headers: {'Authorization': 'Bearer $token'},
      );
      print('📥 Réponse brute des messages: ${res.body}');
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        print('📬 JSON décodé: $data');
        final messages = List<Map<String, dynamic>>.from(data);
        setState(() => _rawMessages = messages.reversed.toList());

        await _decryptVisibleMessages();
      } else {
        _showError('Erreur chargement messages: ${res.body}');
      }
    } catch (e) {
      _showError('Erreur réseau: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _decryptVisibleMessages() async {
    print('🔐 AES ready = ${_aesConversationKey != null}, Messages à décrypter = ${_rawMessages.length}');
    if (_aesConversationKey == null) return;

    for (int i = 0; i < _rawMessages.length && i < _initialDecryptCount; i++) {
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

        final signedPayload = json.encode({
          'encrypted': m['encrypted'],
          'iv': m['iv'],
        });

        print('🧪 Préparation vérification signature pour messageId=$messageId');
        print('📦 encrypted: ${m['encrypted']}, iv: ${m['iv']}, signature: ${m['signature']}, publicKey: ${m['senderPublicKey']}');

        final valid = await EncryptionUtils.verifySignature(
          payload: json.decode(signedPayload),
          signature: m['signature'],
          senderPublicKeyPem: m['senderPublicKey'],
        );
        _verifiedSignatures[messageId] = valid;
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

      WebSocketService().sendMessage({
        'conversationId': widget.conversationId,
        'encrypted': encrypted['encrypted'],
        'iv': encrypted['iv'],
        'keys': {},
        'signature': signatureBase64,
        'senderPublicKey': publicKeyPem,
      });
    } catch (e) {
      _showError('Erreur envoi message: $e');
    } finally {
      setState(() => _sending = false);
    }
  }

  void _onScroll() async {
    if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
      await _decryptVisibleMessages();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  void _attemptReconnect() async {
    if (!mounted) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final token = auth.token;
    if (token != null) {
      WebSocketService().connect(token);
      WebSocketService().subscribeConversation(widget.conversationId);
      WebSocketService().onNewMessage((message) async {
        setState(() => _rawMessages.insert(0, message));
        await _decryptVisibleMessages();
      });
      WebSocketService().onError((errorMessage) {
        _showError('Erreur WebSocket: $errorMessage');
        _attemptReconnect();
      });
    } else {
      _showError('Impossible de se reconnecter : token manquant');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conversation')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
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
                              ? const Icon(Icons.verified, color: Colors.green)
                              : const Icon(Icons.warning_amber, color: Colors.redAccent);
                      return ListTile(
                        title: Text(msg['senderId'] ?? 'Inconnu'),
                        subtitle: Text(decrypted),
                        trailing: icon,
                      );
                    },
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
    );
  }
}
