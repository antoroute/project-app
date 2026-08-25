import { FastifyInstance } from 'fastify';

export type GroupRole = 'owner' | 'admin' | 'member';

export type GroupPermission =
  | 'group:read'
  | 'members:read'
  | 'keys:read'
  | 'keys:manage-own'
  | 'conversation:create'
  | 'join-request:read'
  | 'join-request:handle'
  | 'member-role:set';

export type ConversationPermission =
  | 'conversation:read'
  | 'message:read'
  | 'message:send'
  | 'read-receipt:write'
  | 'readers:read'
  | 'socket:subscribe'
  | 'typing:emit';

const commonGroupPermissions: readonly GroupPermission[] = [
  'group:read',
  'members:read',
  'keys:read',
  'keys:manage-own',
  'conversation:create',
];

const managerPermissions: readonly GroupPermission[] = [
  ...commonGroupPermissions,
  'join-request:read',
  'join-request:handle',
];

export const GROUP_ROLE_PERMISSIONS: Readonly<
  Record<GroupRole, readonly GroupPermission[]>
> = Object.freeze({
  owner: Object.freeze([
    ...managerPermissions,
    'member-role:set' as GroupPermission,
  ]),
  admin: Object.freeze([...managerPermissions]),
  member: Object.freeze([...commonGroupPermissions]),
});

export const CONVERSATION_MEMBER_PERMISSIONS: readonly ConversationPermission[] =
  Object.freeze([
    'conversation:read',
    'message:read',
    'message:send',
    'read-receipt:write',
    'readers:read',
    'socket:subscribe',
    'typing:emit',
  ]);

export function groupRoleAllows(
  role: GroupRole,
  permission: GroupPermission,
): boolean {
  return GROUP_ROLE_PERMISSIONS[role].includes(permission);
}

export function conversationMemberAllows(
  permission: ConversationPermission,
): boolean {
  return CONVERSATION_MEMBER_PERMISSIONS.includes(permission);
}

export interface ConversationAccess {
  conversationId: string;
  groupId: string;
  groupRole: GroupRole;
}

export function initAclService(app: FastifyInstance) {
  async function getGroupRole(
    userId: string,
    groupId: string,
  ): Promise<GroupRole | null> {
    const row = await app.db.oneOrNone(
      `SELECT CASE
                WHEN g.creator_id = $1 THEN 'owner'
                ELSE ug.role
              END AS role
         FROM groups g
         JOIN user_groups ug
           ON ug.group_id = g.id
          AND ug.user_id = $1
        WHERE g.id = $2`,
      [userId, groupId],
    );
    return (row?.role as GroupRole | undefined) ?? null;
  }

  async function hasGroupPermission(
    userId: string,
    groupId: string,
    permission: GroupPermission,
  ): Promise<boolean> {
    const role = await getGroupRole(userId, groupId);
    return role !== null && groupRoleAllows(role, permission);
  }

  async function getConversationAccess(
    userId: string,
    conversationId: string,
  ): Promise<ConversationAccess | null> {
    const row = await app.db.oneOrNone(
      `SELECT c.id AS "conversationId",
              c.group_id AS "groupId",
              CASE
                WHEN g.creator_id = $1 THEN 'owner'
                ELSE ug.role
              END AS "groupRole"
         FROM conversations c
         JOIN conversation_users cu
           ON cu.conversation_id = c.id
          AND cu.user_id = $1
         JOIN groups g ON g.id = c.group_id
         JOIN user_groups ug
           ON ug.group_id = c.group_id
          AND ug.user_id = $1
        WHERE c.id = $2`,
      [userId, conversationId],
    );
    return row as ConversationAccess | null;
  }

  async function hasConversationPermission(
    userId: string,
    conversationId: string,
    permission: ConversationPermission,
  ): Promise<boolean> {
    if (!conversationMemberAllows(permission)) return false;
    return (await getConversationAccess(userId, conversationId)) !== null;
  }

  async function canCreateConversation(
    userId: string,
    groupId: string,
    memberIds: string[],
  ): Promise<boolean> {
    if (
      !(await hasGroupPermission(userId, groupId, 'conversation:create'))
    ) {
      return false;
    }

    const expectedMembers = [...new Set([userId, ...memberIds])];
    const rows = await app.db.any(
      `SELECT user_id AS "userId"
         FROM user_groups
        WHERE group_id = $1
          AND user_id = ANY($2::uuid[])`,
      [groupId, expectedMembers],
    );
    const actualMembers = new Set(rows.map((row: any) => row.userId));
    return expectedMembers.every((memberId) => actualMembers.has(memberId));
  }

  async function canSend(
    senderUserId: string,
    senderDeviceId: string,
    groupId: string,
    conversationId: string,
    recipients: Array<{ userId: string; deviceId: string }>,
  ): Promise<boolean> {
    const access = await getConversationAccess(senderUserId, conversationId);
    if (
      access === null ||
      access.groupId !== groupId ||
      !conversationMemberAllows('message:send')
    ) {
      return false;
    }

    const senderDevice = await app.db.oneOrNone(
      `SELECT 1
         FROM group_device_keys
        WHERE group_id = $1
          AND user_id = $2
          AND device_id = $3
          AND status = 'active'`,
      [groupId, senderUserId, senderDeviceId],
    );
    if (!senderDevice) return false;

    for (const recipient of recipients) {
      const allowedRecipient = await app.db.oneOrNone(
        `SELECT 1
           FROM conversation_users cu
           JOIN conversations c ON c.id = cu.conversation_id
           JOIN user_groups ug
             ON ug.group_id = c.group_id
            AND ug.user_id = cu.user_id
           JOIN group_device_keys gdk
             ON gdk.group_id = c.group_id
            AND gdk.user_id = cu.user_id
            AND gdk.device_id = $4
            AND gdk.status = 'active'
          WHERE cu.conversation_id = $1
            AND cu.user_id = $2
            AND c.group_id = $3`,
        [conversationId, recipient.userId, groupId, recipient.deviceId],
      );
      if (!allowedRecipient) return false;
    }
    return true;
  }

  async function listAccessibleConversationIds(
    userId: string,
    conversationIds: string[],
  ): Promise<string[]> {
    if (conversationIds.length === 0) return [];
    const rows = await app.db.any(
      `SELECT c.id
         FROM conversations c
         JOIN conversation_users cu
           ON cu.conversation_id = c.id
          AND cu.user_id = $1
         JOIN user_groups ug
           ON ug.group_id = c.group_id
          AND ug.user_id = $1
        WHERE c.id = ANY($2::uuid[])`,
      [userId, conversationIds],
    );
    return rows.map((row: any) => row.id as string);
  }

  async function listAllAccessibleConversationIds(
    userId: string,
  ): Promise<string[]> {
    const rows = await app.db.any(
      `SELECT c.id
         FROM conversations c
         JOIN conversation_users cu
           ON cu.conversation_id = c.id
          AND cu.user_id = $1
         JOIN user_groups ug
           ON ug.group_id = c.group_id
          AND ug.user_id = $1`,
      [userId],
    );
    return rows.map((row: any) => row.id as string);
  }

  async function listAccessibleGroupIds(userId: string): Promise<string[]> {
    const rows = await app.db.any(
      `SELECT group_id AS "groupId"
         FROM user_groups
        WHERE user_id = $1`,
      [userId],
    );
    return rows.map((row: any) => row.groupId as string);
  }

  async function markConversationRead(convId: string, userId: string) {
    await app.db.none(
      `UPDATE conversation_users
          SET last_read_at = NOW()
        WHERE conversation_id = $1 AND user_id = $2`,
      [convId, userId],
    );
    const row = await app.db.one(
      `SELECT last_read_at
         FROM conversation_users
        WHERE conversation_id = $1 AND user_id = $2`,
      [convId, userId],
    );
    return row.last_read_at as string;
  }

  async function listReaders(convId: string) {
    return app.db.any(
      `SELECT u.id AS "userId", u.username,
              cu.last_read_at AS "lastReadAt"
         FROM conversation_users cu
         JOIN users u ON u.id = cu.user_id
        WHERE cu.conversation_id = $1`,
      [convId],
    );
  }

  return {
    getGroupRole,
    hasGroupPermission,
    getConversationAccess,
    hasConversationPermission,
    canCreateConversation,
    canSend,
    listAccessibleConversationIds,
    listAllAccessibleConversationIds,
    listAccessibleGroupIds,
    markConversationRead,
    listReaders,
  };
}
