import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_message_app/core/crypto/key_manager_final.dart';
import 'package:flutter_message_app/core/services/secure_string_store.dart';
import 'package:flutter_message_app/core/services/session_device_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const userA = '11111111-1111-4111-8111-111111111111';
  const userB = '22222222-2222-4222-8222-222222222222';
  const deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  group('identifiant d’appareil par compte', () {
    test('isole deux comptes et ignore l’ancien identifiant global', () async {
      final store = MemorySecureStringStore({
        'device_id_v1': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      });
      final generated = <String>[deviceA, deviceB].iterator;
      final service = SessionDeviceService.forTesting(
        storage: store,
        generateDeviceId: () {
          generated.moveNext();
          return generated.current;
        },
      );

      expect(await service.getOrCreateDeviceId(userA), deviceA);
      expect(await service.getOrCreateDeviceId(userA), deviceA);
      expect(await service.getOrCreateDeviceId(userB), deviceB);
      expect(store.values['device_id_v1'], isNot(deviceA));
      expect(
        store.values['device_id_v2:account:$userA'],
        isNot(store.values['device_id_v2:account:$userB']),
      );
    });

    test('recharge la valeur propre au compte après purge mémoire', () async {
      final store = MemorySecureStringStore();
      var generations = 0;
      final service = SessionDeviceService.forTesting(
        storage: store,
        generateDeviceId: () {
          generations += 1;
          return deviceA;
        },
      );

      expect(await service.getOrCreateDeviceId(userA), deviceA);
      await service.clearMemoryCache();
      expect(await service.getOrCreateDeviceId(userA), deviceA);
      expect(generations, 1);
    });

    test('refuse un espace de noms qui n’est pas un UUID de compte', () async {
      final service = SessionDeviceService.forTesting(
        storage: MemorySecureStringStore(),
        generateDeviceId: () => deviceA,
      );

      await expectLater(
        service.getOrCreateDeviceId('../another-account'),
        throwsArgumentError,
      );
    });

    test('ne remplace pas un identifiant stocké invalide', () async {
      final store = MemorySecureStringStore({
        'device_id_v2:account:$userA': 'corrupted',
      });
      var generated = false;
      final service = SessionDeviceService.forTesting(
        storage: store,
        generateDeviceId: () {
          generated = true;
          return deviceA;
        },
      );

      await expectLater(service.getOrCreateDeviceId(userA), throwsStateError);
      expect(generated, isFalse);
      expect(store.writeCount, 0);
    });

    test('sérialise deux créations concurrentes pour le même compte', () async {
      final store = MemorySecureStringStore();
      var generations = 0;
      final service = SessionDeviceService.forTesting(
        storage: store,
        generateDeviceId: () {
          generations += 1;
          return deviceA;
        },
      );

      final ids = await Future.wait([
        service.getOrCreateDeviceId(userA),
        service.getOrCreateDeviceId(userA),
      ]);

      expect(ids, everyElement(deviceA));
      expect(generations, 1);
      expect(store.writeCount, 1);
    });
  });

  group('matériel cryptographique fail-closed', () {
    test('génère uniquement depuis l’appel explicite ensureKeysFor', () async {
      final store = MemorySecureStringStore();
      final manager = KeyManagerFinal.forTesting(storage: store);

      await expectLater(
        manager.loadEd25519KeyPair('group-a', deviceA),
        throwsA(_keyError('missing_or_partial_key_material')),
      );
      expect(store.writeCount, 0);

      await manager.ensureKeysFor('group-a', deviceA);
      expect(store.writeCount, 4);
      expect(await manager.publicKeysBase64('group-a', deviceA), {
        'pk_sig': isA<String>(),
        'pk_kem': isA<String>(),
      });
    });

    test('sérialise deux créations explicites concurrentes', () async {
      final store = MemorySecureStringStore();
      final manager = KeyManagerFinal.forTesting(storage: store);

      await Future.wait([
        manager.ensureKeysFor('group-a', deviceA),
        manager.ensureKeysFor('group-a', deviceA),
      ]);

      expect(store.writeCount, 4);
      await manager.loadEd25519KeyPair('group-a', deviceA);
      await manager.loadX25519KeyPair('group-a', deviceA);
    });

    test('refuse une paire partielle sans supprimer ni remplacer', () async {
      final store = MemorySecureStringStore({
        'v2:group-a:$deviceA:ed25519:seed': base64Encode(
          List<int>.filled(32, 1),
        ),
      });
      final manager = KeyManagerFinal.forTesting(storage: store);

      await expectLater(
        manager.ensureKeysFor('group-a', deviceA),
        throwsA(_keyError('missing_or_partial_key_material')),
      );
      expect(store.writeCount, 0);
      expect(store.deleteCount, 0);
      expect(store.values, hasLength(1));
    });

    test('refuse une clé publique différente du seed', () async {
      final store = MemorySecureStringStore();
      final firstManager = KeyManagerFinal.forTesting(storage: store);
      await firstManager.ensureKeysFor('group-a', deviceA);

      final otherKey = await Ed25519().newKeyPair();
      final otherPublic = await otherKey.extractPublicKey();
      store.values['v2:group-a:$deviceA:ed25519_pub:seed'] = base64Encode(
        otherPublic.bytes,
      );
      final writesBeforeLoad = store.writeCount;
      final secondManager = KeyManagerFinal.forTesting(storage: store);

      await expectLater(
        secondManager.loadEd25519KeyPair('group-a', deviceA),
        throwsA(_keyError('public_key_mismatch')),
      );
      expect(store.writeCount, writesBeforeLoad);
      expect(store.deleteCount, 0);
    });

    test(
      'la purge mémoire force une nouvelle validation du stockage',
      () async {
        final store = MemorySecureStringStore();
        final manager = KeyManagerFinal.forTesting(storage: store);
        await manager.ensureKeysFor('group-a', deviceA);
        await manager.loadX25519KeyPair('group-a', deviceA);

        await manager.clearMemoryCaches();
        store.values['v2:group-a:$deviceA:x25519_pub:seed'] = base64Encode(
          List<int>.filled(32, 0),
        );

        await expectLater(
          manager.loadX25519KeyPair('group-a', deviceA),
          throwsA(_keyError('public_key_mismatch')),
        );
      },
    );
  });
}

Matcher _keyError(String code) => isA<KeyMaterialUnavailableException>().having(
  (error) => error.code,
  'code',
  code,
);

class MemorySecureStringStore implements SecureStringStore {
  MemorySecureStringStore([Map<String, String>? initial])
    : values = <String, String>{...?initial};

  final Map<String, String> values;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCount += 1;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCount += 1;
    values.remove(key);
  }
}
