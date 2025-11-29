// backend/messaging/src/services/acl.ts
// - Vérifie l'appartenance groupe/conversation.
// - Fournit des helpers pour "mark as read" et lister qui a lu (via conversation_users.last_read_at).

import { FastifyInstance } from 'fastify';

export function initAclService(app: FastifyInstance) {

  // Vérifie que user est membre de la conversation, que chaque destinataire aussi (par device)
  async function canSend(senderUserId: string, senderDeviceId: string, groupId: string, convId: string, recipients: Array<{userId:string, deviceId:string}>) {
    // 1) conversation dans le bon groupe ?
    const conv = await app.db.one(
      `SELECT c.id, c.group_id
         FROM conversations c
        WHERE c.id=$1`,
      [convId]
    );
    if (conv.group_id !== groupId) return false;

    // 2) sender membre de la conv
    const s = await app.db.any(
      `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
      [convId, senderUserId]
    );
    if (s.length === 0) return false;

    // CORRECTION CRITIQUE: Vérifier que le device de l'expéditeur est actif
    // Un device révoqué ne peut plus envoyer de messages
    const senderDevice = await app.db.any(
      `SELECT 1 FROM group_device_keys WHERE group_id=$1 AND user_id=$2 AND device_id=$3 AND status='active'`,
      [groupId, senderUserId, senderDeviceId]
    );
    if (senderDevice.length === 0) return false;

    // 3) destinataires membres de la conv ET devices actifs
    for (const r of recipients) {
      const r1 = await app.db.any(
        `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
        [convId, r.userId]
      );
      if (r1.length === 0) return false;

      const r2 = await app.db.any(
        `SELECT 1 FROM group_device_keys WHERE group_id=$1 AND user_id=$2 AND device_id=$3 AND status='active'`,
        [groupId, r.userId, r.deviceId]
      );
      if (r2.length === 0) return false;
    }
    return true;
  }

  // Marquer comme lu: met à jour conversation_users.last_read_at (horodatage serveur)
  async function markConversationRead(convId: string, userId: string) {
    await app.db.none(
      `UPDATE conversation_users
          SET last_read_at = NOW()
        WHERE conversation_id=$1 AND user_id=$2`,
      [convId, userId]
    );
    // retourne la nouvelle valeur
    const row = await app.db.one(
      `SELECT last_read_at FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
      [convId, userId]
    );
    return row.last_read_at as string;
  }

  // Liste des readers: pour chaque membre, donne last_read_at
  async function listReaders(convId: string) {
    const rows = await app.db.any(
      `SELECT u.id as "userId", u.username, cu.last_read_at as "lastReadAt"
         FROM conversation_users cu
         JOIN users u ON u.id = cu.user_id
        WHERE cu.conversation_id=$1`,
      [convId]
    );
    return rows;
  }

  return { canSend, markConversationRead, listReaders };
}
