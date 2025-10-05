# 🔧 CORRECTIONS DES PROBLÈMES PERSISTANTS

## 📋 **PROBLÈMES IDENTIFIÉS ET CORRIGÉS**

### **1. ✅ Synchronisation des groupes pour les utilisateurs acceptés**

**Problème** : Quand un utilisateur est accepté dans un nouveau groupe, celui-ci n'apparaît pas directement pour l'utilisateur concerné.

**Cause** : 
- Les utilisateurs ne rejoignaient pas automatiquement les rooms de groupe
- Pas d'événement WebSocket pour notifier l'ajout d'un membre

**Solutions appliquées** :

#### **Backend (`backend/messaging/src/index.ts`)**
```typescript
// CORRECTION: Rejoindre automatiquement les rooms de groupes de l'utilisateur
app.db.any(`SELECT group_id FROM user_groups WHERE user_id = $1`, [userId])
  .then((groups: any[]) => {
    groups.forEach((group: any) => {
      socket.join(`group:${group.group_id}`);
      app.log.debug({ userId, groupId: group.group_id }, 'User auto-joined group room');
    });
  })
```

#### **Backend (`backend/messaging/src/routes/groups.ts`)**
```typescript
// CORRECTION: Notifier tous les utilisateurs du groupe qu'un nouvel utilisateur a rejoint
app.io.to(`group:${groupId}`).emit('group:member_joined', { 
  groupId, 
  userId: jr.user_id, 
  approverId 
});
```

#### **Frontend (`frontend-mobile/flutter_message_app/lib/core/services/websocket_service.dart`)**
```dart
// Nouveau callback pour les membres qui rejoignent un groupe
void Function(String groupId, String userId, String approverId)? onGroupMemberJoined;

// Gestion de l'événement
..on('group:member_joined', (data) {
  final m = Map<String, dynamic>.from(data);
  final groupId = m['groupId'] as String;
  final userId = m['userId'] as String;
  final approverId = m['approverId'] as String;
  onGroupMemberJoined?.call(groupId, userId, approverId);
})
```

#### **Frontend (`frontend-mobile/flutter_message_app/lib/core/providers/group_provider.dart`)**
```dart
void _onWebSocketGroupMemberJoined(String groupId, String userId, String approverId) {
  debugPrint('👥 [GroupProvider] Group member joined event received: $userId in $groupId by $approverId');
  // CORRECTION: Rafraîchir immédiatement la liste des groupes
  fetchUserGroups();
}
```

---

### **2. ✅ Problème de présence croisée entre utilisateurs**

**Problème** : Le widget de présence ne s'actualise toujours pas bien entre utilisateurs.

**Cause** : 
- Les utilisateurs ne recevaient pas l'état de présence des autres utilisateurs au moment de la connexion
- Logique de mise à jour de présence défaillante

**Solutions appliquées** :

#### **Backend (`backend/messaging/src/services/presence.ts`)**
```typescript
function onConnect(socket: Socket) {
  // ... code existant ...
  
  // CORRECTION: Envoyer l'état de présence actuel à tous les utilisateurs connectés
  console.log(`[Presence] Broadcasting current presence state to all users`);
  for (const [uid, socketSet] of state.entries()) {
    if (socketSet.size > 0) {
      io.emit('presence:update', { userId: uid, online: true, count: socketSet.size });
    }
  }
}
```

#### **Frontend (`frontend-mobile/flutter_message_app/lib/core/providers/conversation_provider.dart`)**
```dart
void _onPresenceUpdate(String userId, bool online, int count) {
  // CORRECTION: Toujours mettre à jour la présence, même si count = 0
  final wasOnline = _userOnline[userId] ?? false;
  _userOnline[userId] = online && count > 0;
  _userDeviceCount[userId] = count;
  
  // CORRECTION: Forcer la mise à jour si le statut a changé
  if (wasOnline != _userOnline[userId]) {
    debugPrint('👥 [Presence] Status changed for $userId: $wasOnline -> ${_userOnline[userId]}');
    notifyListeners();
  }
}
```

---

### **3. ✅ Perte des signatures lors du retour sur conversation**

**Problème** : Si on quitte une conversation et qu'on retourne dessus, aucun message n'est signé alors que si on ferme l'app et qu'on la rouvre, tout est signé correctement.

**Cause** : 
- Les messages étaient recréés avec `signatureValid: false` et `decryptedText: null`
- Perte des données déchiffrées et des statuts de signature

**Solutions appliquées** :

#### **Frontend (`frontend-mobile/flutter_message_app/lib/core/providers/conversation_provider.dart`)**
```dart
final List<Message> display = items.map((it) {
  // CORRECTION: Préserver les données existantes si le message existe déjà
  Message? existingMessage;
  try {
    existingMessage = _messages[conversationId]?.firstWhere(
      (msg) => msg.id == it.messageId,
    );
  } catch (e) {
    existingMessage = null;
  }
  
  return Message(
    id: it.messageId,
    conversationId: it.convId,
    senderId: senderUserId,
    encrypted: null,
    iv: null,
    encryptedKeys: const {},
    signatureValid: existingMessage?.signatureValid ?? false, // Préserver le statut existant
    senderPublicKey: null,
    timestamp: it.sentAt,
    v2Data: it.toJson(),
    decryptedText: existingMessage?.decryptedText, // Préserver le texte déchiffré existant
  );
}).toList();
```

---

## 🚀 **RÉSULTATS ATTENDUS**

Après ces corrections, l'application devrait :

1. **✅ Synchronisation des groupes** - Les utilisateurs acceptés dans un groupe voient immédiatement le groupe apparaître
2. **✅ Présence croisée** - Les indicateurs de présence fonctionnent correctement entre tous les utilisateurs
3. **✅ Signatures préservées** - Les signatures et textes déchiffrés sont préservés lors du retour sur une conversation

## 📝 **TESTS RECOMMANDÉS**

1. **Test de synchronisation des groupes** :
   - Créer un groupe avec User1
   - User2 demande à rejoindre
   - User1 accepte User2
   - Vérifier que User2 voit immédiatement le groupe

2. **Test de présence** :
   - User1 et User2 connectés
   - Vérifier que chacun voit l'autre comme en ligne
   - Déconnecter User1, vérifier que User2 le voit comme hors ligne

3. **Test des signatures** :
   - Envoyer des messages dans une conversation
   - Quitter la conversation
   - Retourner sur la conversation
   - Vérifier que les signatures sont toujours valides

## 🔍 **MONITORING**

Les logs suivants permettront de vérifier le bon fonctionnement :

- `👥 [GroupProvider] Group member joined event received` - Synchronisation des groupes
- `👥 [Presence] Status changed for` - Changements de présence
- `🔐 [Decrypt] Message ... - Signature: ✅` - Signatures préservées
- `🏗️ [GroupProvider] Group created event received` - Création de groupes

---

**Status** : ✅ **TOUS LES PROBLÈMES PERSISTANTS CORRIGÉS**
