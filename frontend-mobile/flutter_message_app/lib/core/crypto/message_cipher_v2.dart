import 'dart:convert';
import 'dart:math' as math;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:uuid/uuid.dart';

class MessageCipherV2 {
  static final AesGcm _aead = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => Random.secure().nextInt(256)));

  static String _b64(Uint8List bytes) => base64.encode(bytes);
  
  /// Nettoie et valide une chaîne Base64
  static String _cleanBase64(String input) {
    // Supprimer les espaces, retours à la ligne et caractères invalides
    String cleaned = input.trim().replaceAll(RegExp(r'[\s\n\r]'), '');
    
    // Vérifier que la chaîne ne contient que des caractères Base64 valides
    if (!RegExp(r'^[A-Za-z0-9+/=_-]*$').hasMatch(cleaned)) {
      throw FormatException('Invalid Base64 characters in: $input');
    }
    
    // Gérer les variantes Base64 URL-safe
    cleaned = cleaned.replaceAll('-', '+').replaceAll('_', '/');
    
    // Ajouter padding si nécessaire
    while (cleaned.length % 4 != 0) {
      cleaned += '=';
    }
    
    return cleaned;
  }

  static Uint8List _concatCanonical(
    Map<String, dynamic> payload,
  ) {
    // Deterministic concatenation of key fields for signing
    final sb = StringBuffer();
    sb.write(payload['v']);
    final alg = payload['alg'] as Map<String, dynamic>;
    sb.write(alg['kem']);
    sb.write(alg['kdf']);
    sb.write(alg['aead']);
    sb.write(alg['sig']);
    sb.write(payload['groupId']);
    sb.write(payload['convId']);
    sb.write(payload['messageId']);
    sb.write(payload['sentAt']);
    final sender = payload['sender'] as Map<String, dynamic>;
    sb.write(sender['userId']);
    sb.write(sender['deviceId']);
    sb.write(sender['eph_pub']);
    sb.write(sender['key_version']);
    final recipients = payload['recipients'] as List<dynamic>;
    for (final r in recipients) {
      final m = r as Map<String, dynamic>;
      sb.write(m['userId']);
      sb.write(m['deviceId']);
      sb.write(m['wrap']);
      sb.write(m['nonce']);
    }
    sb.write(payload['iv']);
    sb.write(payload['ciphertext']);
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  static Future<Map<String, dynamic>> encrypt({
    required String groupId,
    required String convId,
    required String senderUserId,
    required String senderDeviceId,
    required List<GroupDeviceKeyEntry> recipientsDevices,
    required Uint8List plaintext,
  }) async {
    // message parameters
    final String messageId = const Uuid().v4();
    final int sentAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final Uint8List mk = _randomBytes(32);
    final Uint8List iv = _randomBytes(12);

    // content encryption
    final contentSecret = SecretKey(mk);
    final secretBox = await _aead.encrypt(
      plaintext,
      secretKey: contentSecret,
      nonce: iv,
    );
    final Uint8List ciphertext = Uint8List.fromList(secretBox.cipherText + secretBox.mac.bytes);

    // ephemeral for KEM
    final x = X25519();
    final eph = await x.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final String ephPubB64 = _b64(Uint8List.fromList(ephPub.bytes));

    // salt for HKDF
    final Uint8List salt = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode('$messageId:${_b64(_randomBytes(16))}')).bytes,
    );

    // wrap mk per recipient
    final List<Map<String, String>> recipients = [];
    var validRecipientsCount = 0;
    for (final entry in recipientsDevices) {
      // Skip recipients with empty keys (they haven't published their keys yet)
      if (entry.pkKemB64.isEmpty) {
        continue;
      }
      
      final recipientPub = SimplePublicKey(
        base64.decode(_cleanBase64(entry.pkKemB64)),
        type: KeyPairType.x25519,
      );
      final shared = await x.sharedSecretKey(keyPair: eph, remotePublicKey: recipientPub);
      final infoData = 'project-app/v2 $groupId $convId ${entry.userId} ${entry.deviceId}';
      final kek = await _hkdf.deriveKey(
        secretKey: shared,
        nonce: salt,
        info: utf8.encode(infoData),
      );
      final kekBytes = Uint8List.fromList(await kek.extractBytes());
      final wrapNonce = _randomBytes(12);
      final wrapBox = await _aead.encrypt(
        mk,
        secretKey: SecretKey(kekBytes),
        nonce: wrapNonce,
      );
      final wrapped = Uint8List.fromList(wrapBox.cipherText + wrapBox.mac.bytes);
      recipients.add({
        'userId': entry.userId,
        'deviceId': entry.deviceId,
        'wrap': _b64(wrapped),
        'nonce': _b64(wrapNonce),
      });
      validRecipientsCount++;
    }

    // Check if we have at least one valid recipient
    if (validRecipientsCount == 0) {
      throw Exception('Aucun destinataire valide trouvé - tous les utilisateurs doivent publier leurs clés d\'abord');
    }

    // assemble payload (without sig)
    final Map<String, dynamic> payload = {
      'v': 2,
      'alg': {'kem': 'X25519', 'kdf': 'HKDF-SHA256', 'aead': 'AES-256-GCM', 'sig': 'Ed25519'},
      'groupId': groupId,
      'convId': convId,
      'messageId': messageId,
      'sentAt': sentAt,
      'sender': {
        'userId': senderUserId,
        'deviceId': senderDeviceId,
        'eph_pub': ephPubB64,
        'key_version': 1,
      },
      'recipients': recipients,
      'iv': _b64(iv),
      'ciphertext': _b64(ciphertext),
      'salt': _b64(salt), // Ajouter la salt au payload pour le déchiffrement
    };

    // sign
    debugPrint('📝 Signature pour sender $senderDeviceId:');
    final edKey = await KeyManagerFinal.instance.loadEd25519KeyPair(groupId, senderDeviceId);
    debugPrint('  - Ed25519 keypair obtenu: ✅');
    final ed = Ed25519();
    final signature = await ed.sign(_concatCanonical(payload), keyPair: edKey);
    debugPrint('  - Signature créée: ${signature.bytes.length} bytes');
    
    final sigB64 = _b64(Uint8List.fromList(signature.bytes));
    debugPrint('  - Signature encoded length: ${sigB64.length} chars');
    debugPrint('  - Signature encoded preview: ${sigB64.substring(0, math.min(20, sigB64.length))}...');
    
    payload['sig'] = sigB64;

    return payload;
  }

  /// Déchiffrement rapide SANS vérification de signature (pour le chargement initial)
  static Future<Map<String, dynamic>> decryptFast({
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
  }) async {
    // Vérifier que les champs requis ne sont pas null
    final ephPubB64 = messageV2['senderEphPub'] as String?;
    if (ephPubB64 == null) {
      throw Exception('senderEphPub is null in messageV2');
    }

    // unwrap mk (même logique que decrypt normal)
    final x = X25519();
    final myKey = await KeyManagerFinal.instance.loadX25519KeyPair(groupId, myDeviceId);
    final shared = await x.sharedSecretKey(
      keyPair: myKey,
      remotePublicKey: SimplePublicKey(base64.decode(_cleanBase64(ephPubB64)), type: KeyPairType.x25519),
    );
    
    // Récupérer la salt depuis le payload (ou fallback si pas disponible)
    final Uint8List salt;
    if (messageV2.containsKey('salt')) {
      salt = base64.decode(_cleanBase64(messageV2['salt'] as String));
    } else {
      // Fallback pour compatibilité avec anciens messages
      salt = Uint8List.fromList(
        crypto.sha256.convert(utf8.encode('${messageV2['messageId']}:${_b64(_randomBytes(16))}')).bytes,
      );
    }

    final infoData = 'project-app/v2 $groupId ${messageV2['convId']} $myUserId $myDeviceId';
    final kek = await _hkdf.deriveKey(
      secretKey: SecretKey(Uint8List.fromList(await shared.extractBytes())),
      nonce: salt,
      info: utf8.encode(infoData),
    );
    final kekBytes = Uint8List.fromList(await kek.extractBytes());

    // Trouver notre entrée dans wrappedKeys
    final wrappedKeys = messageV2['wrappedKeys'] as List<dynamic>;
    final mine = wrappedKeys.firstWhere(
      (w) => w['userId'] == myUserId && w['deviceId'] == myDeviceId,
    );

    // unwrap mk
    final wrapBytes = base64.decode(_cleanBase64(mine['wrap'] as String));
    final wrapNonce = base64.decode(_cleanBase64(mine['nonce'] as String));
    final macLen = 16; // AES-GCM tag size
    final cipherLen = wrapBytes.length - macLen;
    final wrapBox = SecretBox(
      wrapBytes.sublist(0, cipherLen),
      nonce: wrapNonce,
      mac: Mac(wrapBytes.sublist(cipherLen)),
    );
    final mkBytes = await _aead.decrypt(
      wrapBox,
      secretKey: SecretKey(kekBytes),
    );

    // decrypt content avec validation Base64 (SANS vérification de signature)
    String ivB64 = messageV2['iv'] as String;
    String ctB64 = messageV2['ciphertext'] as String;
    
    // Validation et nettoyage Base64
    ivB64 = _cleanBase64(ivB64);
    ctB64 = _cleanBase64(ctB64);
    
    final iv = base64.decode(ivB64);
    final ct = base64.decode(ctB64);
    final macLen2 = 16;
    final ctLen = ct.length - macLen2;
    final contentBox = SecretBox(
      ct.sublist(0, ctLen),
      nonce: iv,
      mac: Mac(ct.sublist(ctLen)),
    );
    final clear = await _aead.decrypt(
      contentBox,
      secretKey: SecretKey(mkBytes),
    );
    
    return {
      'decryptedText': Uint8List.fromList(clear),
      'signatureValid': false, // Marqué comme non vérifié pour le mode rapide
    };
  }

  static Future<Map<String, dynamic>> decrypt({
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
  }) async {
    // select recipient wrap
    final List<dynamic> recips = messageV2['recipients'] as List<dynamic>;
    
    Map<String, dynamic>? mine;
    for (final r in recips) {
      final m = r as Map<String, dynamic>;
      if (m['userId'] == myUserId && m['deviceId'] == myDeviceId) {
        mine = m;
        break;
      }
    }
    if (mine == null) {
      throw Exception('No wrap for this device');
    }

    // derive KEK
    final sender = messageV2['sender'] as Map<String, dynamic>;
    final senderUserId = sender['userId'] as String;
    final senderDeviceId = sender['deviceId'] as String;
    final ephPubB64 = sender['eph_pub'] as String;

    final x = X25519();
    final myKey = await KeyManagerFinal.instance.loadX25519KeyPair(groupId, myDeviceId);
    final shared = await x.sharedSecretKey(
      keyPair: myKey,
      remotePublicKey: SimplePublicKey(base64.decode(_cleanBase64(ephPubB64)), type: KeyPairType.x25519),
    );
    
    // Récupérer la salt depuis le payload (ou fallback si pas disponible)
    final Uint8List salt;
    if (messageV2.containsKey('salt')) {
      salt = base64.decode(_cleanBase64(messageV2['salt'] as String));
    } else {
      // Fallback pour compatibilité avec anciens messages
      salt = Uint8List.fromList(
        crypto.sha256.convert(utf8.encode('${messageV2['messageId']}:${_b64(_randomBytes(16))}')).bytes,
      );
    }
    
    final infoData = 'project-app/v2 $groupId ${messageV2['convId']} $myUserId $myDeviceId';
    final kek = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: utf8.encode(infoData),
    );
    final kekBytes = Uint8List.fromList(await kek.extractBytes());

    // unwrap mk
    final wrapBytes = base64.decode(_cleanBase64(mine['wrap'] as String));
    final wrapNonce = base64.decode(_cleanBase64(mine['nonce'] as String));
    final macLen = 16; // AES-GCM tag size
    final cipherLen = wrapBytes.length - macLen;
    final wrapBox = SecretBox(
      wrapBytes.sublist(0, cipherLen),
      nonce: wrapNonce,
      mac: Mac(wrapBytes.sublist(cipherLen)),
    );
    final mkBytes = await _aead.decrypt(
      wrapBox,
      secretKey: SecretKey(kekBytes),
    );

    // verify signature with sender Ed25519 public key from directory
    final ed = Ed25519();
    final entries = await keyDirectory.getGroupDevices(groupId);
    
    final senderEntry = entries.firstWhere(
      (e) => e.userId == senderUserId && e.deviceId == senderDeviceId,
      orElse: () => throw Exception('Missing sender public key in directory'),
    );
    
    if (senderEntry.pkSigB64.isEmpty) {
      throw Exception('⛔ senderEntry.pkSigB64 est vide - impossible de vérifier la signature');
    }
    
    final sigPubBytes = base64.decode(_cleanBase64(senderEntry.pkSigB64));
    final pub = SimplePublicKey(sigPubBytes, type: KeyPairType.ed25519);
    
    // Debug de la signature avant décodage
    final sigString = messageV2['sig'] as String;
    final sigBytes = base64.decode(_cleanBase64(sigString));
    
    final verified = await ed.verify(
      _concatCanonical(messageV2),
      signature: Signature(sigBytes, publicKey: pub),
    );

    // decrypt content avec validation Base64
    String ivB64 = messageV2['iv'] as String;
    String ctB64 = messageV2['ciphertext'] as String;
    
    // Validation et nettoyage Base64
    ivB64 = _cleanBase64(ivB64);
    ctB64 = _cleanBase64(ctB64);
    
    final iv = base64.decode(ivB64);
    final ct = base64.decode(ctB64);
    final macLen2 = 16;
    final ctLen = ct.length - macLen2;
    final contentBox = SecretBox(
      ct.sublist(0, ctLen),
      nonce: iv,
      mac: Mac(ct.sublist(ctLen)),
    );
    final clear = await _aead.decrypt(
      contentBox,
      secretKey: SecretKey(mkBytes),
    );
    
    return {
      'decryptedText': Uint8List.fromList(clear),
      'signatureValid': verified,
    };
  }
}