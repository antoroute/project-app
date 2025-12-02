import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';
import 'package:flutter_message_app/core/services/key_directory_service.dart';
import 'package:flutter_message_app/core/services/message_key_cache.dart';
import 'package:flutter_message_app/core/services/performance_benchmark.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_service.dart';
import 'package:flutter_message_app/core/crypto/crypto_isolate_data.dart';
import 'package:uuid/uuid.dart';

class MessageCipherV2 {
  static final AesGcm _aead = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => Random.secure().nextInt(256)));

  static String _b64(Uint8List bytes) => base64.encode(bytes);
  
  /// Valide les données V2 d'un message avant déchiffrement
  static bool _validateMessageV2Data(Map<String, dynamic> messageV2) {
    try {
      // Vérifier les champs obligatoires
      final requiredFields = [
        'v', 'alg', 'groupId', 'convId', 'messageId', 'sentAt',
        'sender', 'recipients', 'iv', 'ciphertext', 'sig'
      ];
      
      for (final field in requiredFields) {
        if (!messageV2.containsKey(field) || messageV2[field] == null) {
          debugPrint('❌ Champ manquant dans V2: $field');
          return false;
        }
      }
      
      // Vérifier la structure du sender
      final sender = messageV2['sender'] as Map<String, dynamic>?;
      if (sender == null || 
          !sender.containsKey('userId') || 
          !sender.containsKey('deviceId') ||
          !sender.containsKey('eph_pub')) {
        debugPrint('❌ Structure sender invalide');
        return false;
      }
      
      // Vérifier les recipients
      final recipients = messageV2['recipients'] as List<dynamic>?;
      if (recipients == null || recipients.isEmpty) {
        debugPrint('❌ Aucun recipient trouvé');
        return false;
      }
      
      // Vérifier que les données Base64 sont valides
      final ciphertext = messageV2['ciphertext'] as String?;
      if (ciphertext == null || ciphertext.isEmpty) {
        debugPrint('❌ Ciphertext vide');
        return false;
      }
      
      try {
        base64.decode(ciphertext);
      } catch (e) {
        debugPrint('❌ Ciphertext Base64 invalide: $e');
        return false;
      }
      
      return true;
    } catch (e) {
      debugPrint('❌ Erreur validation V2: $e');
      return false;
    }
  }
  
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
    
    // Signer le hash du ciphertext au lieu du ciphertext complet
    // Cela résout le problème de validation de signature pour les messages longs
    final ciphertextB64 = payload['ciphertext'] as String;
    final ciphertextHash = crypto.sha256.convert(utf8.encode(ciphertextB64)).toString();
    
    sb.write(ciphertextHash);
    
    final canonicalString = sb.toString();
    
    return Uint8List.fromList(utf8.encode(canonicalString));
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
        // Skip recipients with empty keys
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
    final edKey = await KeyManagerFinal.instance.loadEd25519KeyPair(groupId, senderDeviceId);
    final ed = Ed25519();
    final signature = await ed.sign(_concatCanonical(payload), keyPair: edKey);
    final sigB64 = _b64(Uint8List.fromList(signature.bytes));
    payload['sig'] = sigB64;

    return payload;
  }

  /// 🚀 OPTIMISATION: Déchiffrement rapide SANS vérification de signature
  /// Utilise le cache de message keys pour éviter la re-dérivation
  /// [priority] : 0 = normal, 1 = haute priorité (messages visibles)
  static Future<Map<String, dynamic>> decryptFast({
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
    int priority = 0,
  }) async {
    // 📊 BENCHMARK: Mesurer le temps total de decryptFast
    return await PerformanceBenchmark.instance.measureAsync(
      'decryptFast_total',
      () async {
    // Validation des données V2 avant déchiffrement
    if (!_validateMessageV2Data(messageV2)) {
      throw Exception('Données V2 invalides ou incomplètes');
    }
    
    final messageId = messageV2['messageId'] as String;
    
    // 🚀 OPTIMISATION: Essayer d'abord de récupérer la message key depuis le cache
        final cachedKey = await PerformanceBenchmark.instance.measureAsync(
          'decryptFast_cache_lookup',
          () async => MessageKeyCache.instance.getMessageKey(messageId),
        );
    
    if (cachedKey != null) {
          // 📊 BENCHMARK: Mesurer le déchiffrement avec cache
          return await PerformanceBenchmark.instance.measureAsync(
            'decryptFast_with_cache',
            () async => await _decryptWithCachedKey(messageId, cachedKey, messageV2),
          );
    } else {
          // 📊 BENCHMARK: Mesurer la dérivation complète (sans cache)
          return await PerformanceBenchmark.instance.measureAsync(
            'decryptFast_without_cache',
            () async {
      // Clé pas en cache : utiliser le pipeline complet dans l'Isolate
      // 🚀 OPTIMISATION: Pipeline complet (X25519 ECDH + HKDF + AES-GCM Unwrap + AES-GCM Decrypt)
      
      // 1. Préparer toutes les données nécessaires
      final sender = messageV2['sender'] as Map<String, dynamic>;
      final ephPubB64 = sender['eph_pub'] as String;
      
      if (ephPubB64.isEmpty) {
        throw Exception('sender.eph_pub is empty in messageV2');
      }

              final myPrivateKeyBytes = await KeyManagerFinal.instance.getX25519PrivateKeyBytes(groupId, myDeviceId);
              final remotePublicKeyBytes = base64.decode(_cleanBase64(ephPubB64));
      
      // Récupérer la salt depuis le payload
      if (!messageV2.containsKey('salt')) {
        throw Exception('salt is required in messageV2');
      }
      final salt = base64.decode(_cleanBase64(messageV2['salt'] as String));

      // Récupérer les recipients
      final recipients = messageV2['recipients'] as List<dynamic>;
      if (recipients.isEmpty) {
        throw Exception('No recipients found in messageV2');
      }
      
      final mine = recipients.firstWhere(
        (w) => w['userId'] == myUserId && w['deviceId'] == myDeviceId,
        orElse: () => throw Exception('No wrap for this device'),
      );

      final wrapBytes = base64.decode(_cleanBase64(mine['wrap'] as String));
      final wrapNonce = base64.decode(_cleanBase64(mine['nonce'] as String));
      
      final iv = base64.decode(_cleanBase64(messageV2['iv'] as String));
      final ciphertext = base64.decode(_cleanBase64(messageV2['ciphertext'] as String));
      
      // 2. Créer la tâche pipeline
      final task = DecryptPipelineTask(
        taskId: messageId,
        priority: priority,
        myPrivateKeyBytes: myPrivateKeyBytes,
        remotePublicKeyBytes: remotePublicKeyBytes,
        groupId: groupId,
        convId: messageV2['convId'] as String,
        myUserId: myUserId,
        myDeviceId: myDeviceId,
        salt: salt,
        wrapBytes: wrapBytes,
        wrapNonce: wrapNonce,
        iv: iv,
        ciphertext: ciphertext,
      );
      
      // 3. Exécuter le pipeline complet dans l'Isolate
      final result = await PerformanceBenchmark.instance.measureAsync(
        'decryptFast_pipeline_isolate',
        () => CryptoIsolateService.instance.executeDecryptPipeline(task),
                  );
      
      if (result.error != null) {
        debugPrint('❌ [decryptFast] Erreur pipeline pour $messageId: ${result.error}');
        throw Exception('Pipeline error: ${result.error}');
      }
      
      if (result.decryptedTextBytes == null) {
        debugPrint('❌ [decryptFast] Pipeline retourné null pour $messageId');
        throw Exception('Pipeline returned null decrypted text');
      }
      
      // Validation : vérifier que le résultat n'est pas vide
      if (result.decryptedTextBytes!.isEmpty) {
        debugPrint('❌ [decryptFast] Pipeline retourné bytes vides pour $messageId');
        throw Exception('Pipeline returned empty decrypted text');
      }
      
      // 4. Retourner le résultat
      return {
        'decryptedText': result.decryptedTextBytes!,
        'signatureValid': false, // Pas de vérification dans decryptFast
      };
            },
          );
        }
      },
    );
  }
  
  /// Helper: Déchiffre le contenu avec une clé déjà dérivée (cache)
  static Future<Map<String, dynamic>> _decryptWithCachedKey(
    String messageId,
    Uint8List mkBytes,
    Map<String, dynamic> messageV2,
  ) async {
    return await _decryptContent(messageV2, mkBytes);
  }
  
  /// Helper: Déchiffre le contenu du message
  static Future<Map<String, dynamic>> _decryptContent(
    Map<String, dynamic> messageV2,
    Uint8List mkBytes,
  ) async {
    return await PerformanceBenchmark.instance.measureAsync(
      'decryptFast_aes_decrypt',
      () async {
    // decrypt content avec validation Base64 (SANS vérification de signature)
    String ivB64 = messageV2['iv'] as String;
    String ctB64 = messageV2['ciphertext'] as String;
    
    // Validation et nettoyage Base64
    ivB64 = _cleanBase64(ivB64);
    ctB64 = _cleanBase64(ctB64);
    
    final iv = base64.decode(ivB64);
    final ct = base64.decode(ctB64);
    final macLen2 = 16;
    
    // CORRECTION: Validation pour éviter RangeError
    if (ct.length < macLen2) {
      throw Exception('Ciphertext trop court: ${ct.length} < $macLen2');
    }
    
    final ctLen = ct.length - macLen2;
    if (ctLen < 0) {
      throw Exception('Longueur ciphertext invalide: $ctLen');
    }
    
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
      },
    );
  }

  static Future<Map<String, dynamic>> decrypt({
    required String groupId,
    required String myUserId,
    required String myDeviceId,
    required Map<String, dynamic> messageV2,
    required KeyDirectoryService keyDirectory,
  }) async {
    // Récupérer les recipients
    final recipients = messageV2['recipients'] as List<dynamic>;
    if (recipients.isEmpty) {
      throw Exception('No recipients found in messageV2');
    }
    
    Map<String, dynamic>? mine;
    for (final r in recipients) {
      final m = r as Map<String, dynamic>;
      if (m['userId'] == myUserId && m['deviceId'] == myDeviceId) {
        mine = m;
        break;
      }
    }
    if (mine == null) {
      throw Exception('No wrap for this device');
    }

    // Récupérer les informations du sender
    final sender = messageV2['sender'] as Map<String, dynamic>;
    final senderUserId = sender['userId'] as String;
    final senderDeviceId = sender['deviceId'] as String;
    final ephPubB64 = sender['eph_pub'] as String;

    // 🚀 OPTIMISATION: X25519 ECDH dans un Isolate (goulot d'étranglement principal)
    // Extraire les bytes des clés (thread principal)
    final myPrivateKeyBytes = await KeyManagerFinal.instance.getX25519PrivateKeyBytes(groupId, myDeviceId);
    final remotePublicKeyBytes = base64.decode(_cleanBase64(ephPubB64));
    
    // Créer la tâche pour l'Isolate
    final task = X25519EcdhTask(
      taskId: messageV2['messageId'] as String,
      myPrivateKeyBytes: myPrivateKeyBytes,
      remotePublicKeyBytes: remotePublicKeyBytes,
    );
    
    // Exécuter X25519 ECDH dans l'Isolate
    final ecdhResult = await CryptoIsolateService.instance.executeX25519Ecdh(task);
    
    if (ecdhResult.error != null) {
      throw Exception('X25519 ECDH error: ${ecdhResult.error}');
    }
    
    if (ecdhResult.sharedSecretBytes == null) {
      throw Exception('X25519 ECDH returned null shared secret');
    }
    
    // Créer un SecretKey depuis les bytes pour HKDF
    final shared = SecretKey(ecdhResult.sharedSecretBytes!);
    
    // Récupérer la salt depuis le payload
    if (!messageV2.containsKey('salt')) {
      throw Exception('salt is required in messageV2');
    }
    final salt = base64.decode(_cleanBase64(messageV2['salt'] as String));
    
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
    
    // CORRECTION: Validation pour éviter RangeError
    if (wrapBytes.length < macLen) {
      throw Exception('Wrap bytes trop courts: ${wrapBytes.length} < $macLen');
    }
    
    final cipherLen = wrapBytes.length - macLen;
    if (cipherLen < 0) {
      throw Exception('Longueur cipher invalide: $cipherLen');
    }
    
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
    
    // CORRECTION: Validation pour éviter RangeError
    if (ct.length < macLen2) {
      throw Exception('Ciphertext trop court: ${ct.length} < $macLen2');
    }
    
    final ctLen = ct.length - macLen2;
    if (ctLen < 0) {
      throw Exception('Longueur ciphertext invalide: $ctLen');
    }
    
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