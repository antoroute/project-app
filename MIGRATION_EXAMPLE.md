# Test de Migration vers KeyManagerV3

## 🧪 **EXEMPLE DE MIGRATION**

Voici comment migrer un fichier existant vers KeyManagerV3 :

### **AVANT (KeyManagerV2)**
```dart
// Dans message_cipher_v2.dart
import 'package:flutter_message_app/core/crypto/key_manager_v2.dart';

// Utilisation
final edKeyPair = await KeyManagerV2.instance.loadEd25519KeyPair(groupId, deviceId);
final xKeyPair = await KeyManagerV2.instance.loadX25519KeyPair(groupId, deviceId);
```

### **APRÈS (KeyManagerV3)**
```dart
// Dans message_cipher_v2.dart
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';

// Utilisation (identique !)
final edKeyPair = await KeyManagerV3.instance.loadEd25519KeyPair(groupId, deviceId);
final xKeyPair = await KeyManagerV3.instance.loadX25519KeyPair(groupId, deviceId);
```

## 🔧 **MIGRATION ÉTAPE PAR ÉTAPE**

### **Étape 1 : Remplacer l'import**
```dart
// AVANT
import 'package:flutter_message_app/core/crypto/key_manager_v2.dart';

// APRÈS
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';
```

### **Étape 2 : Remplacer les appels**
```dart
// AVANT
KeyManagerV2.instance.methodName()

// APRÈS
KeyManagerV3.instance.methodName()
```

### **Étape 3 : Tester le fonctionnement**
- ✅ Génération de clés
- ✅ Cache mémoire
- ✅ Déchiffrement des messages
- ✅ Pas d'erreur "Failed to access X25519 keypair"

## 📋 **FICHIERS À MIGRER**

### **1. message_cipher_v2.dart**
```dart
// Ligne 8
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';

// Lignes utilisant KeyManagerV2.instance
// → Remplacer par KeyManagerV3.instance
```

### **2. conversation_provider.dart**
```dart
// Ligne 13
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';

// Lignes utilisant KeyManagerV2.instance
// → Remplacer par KeyManagerV3.instance
```

### **3. group_provider.dart**
```dart
// Ligne 13
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';

// Lignes utilisant KeyManagerV2.instance
// → Remplacer par KeyManagerV3.instance
```

### **4. group_screen.dart**
```dart
// Ligne 13
import 'package:flutter_message_app/core/crypto/key_manager_v3.dart';

// Lignes utilisant KeyManagerV2.instance
// → Remplacer par KeyManagerV3.instance
```

## 🎯 **RÉSULTAT ATTENDU**

Après migration, vous devriez voir :
- ✅ **Pas d'erreur** "Failed to access X25519 keypair"
- ✅ **Cache mémoire** fonctionnel pendant la session
- ✅ **Déchiffrement** des messages fonctionnel
- ✅ **Performance améliorée** (pas de régénération constante)

## 🚀 **PROCHAINES ÉTAPES**

1. **Migrer un fichier** à la fois
2. **Tester chaque migration**
3. **Valider le fonctionnement**
4. **Migrer le fichier suivant**

**Cette approche garantit une migration sûre et progressive !** 🎯
