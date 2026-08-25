import { FastifyInstance } from 'fastify';

import type { DbExecutor } from '../plugins/db.js';

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

interface AclQueryOptions {
  executor?: DbExecutor;
  lock?: boolean;
}

export function initAclService(app: FastifyInstance) {
  async function getGroupRole(
    userId: string,
    groupId: string,
    options: AclQueryOptions = {},
  ): Promise<GroupRole | null> {
    const db = options.executor ?? app.db;
    const lockClause = options.lock ? 'FOR SHARE OF g, ug' : '';
    const row = await db.oneOrNone(
      `SELECT CASE
                WHEN g.creator_id = $1 THEN 'owner'
                ELSE ug.role
              END AS role
         FROM groups g
         JOIN user_groups ug
           ON ug.group_id = g.id
          AND ug.user_id = $1
        WHERE g.id = $2
        ${lockClause}`,
      [userId, groupId],
    );
    return (row?.role as GroupRole | undefined) ?? null;
  }

  async function hasGroupPermission(
    userId: string,
    groupId: string,
    permission: GroupPermission,
    options: AclQueryOptions = {},
  ): Promise<boolean> {
    const role = await getGroupRole(userId, groupId, options);
    return role !== null && groupRoleAllows(role, permission);
  }

  async function getConversationAccess(
    userId: string,
    conversationId: string,
    options: AclQueryOptions = {},
  ): Promise<ConversationAccess | null> {
    const db = options.executor ?? app.db;
    const lockClause = options.lock ? 'FOR SHARE OF c, cu, g, ug' : '';
    const row = await db.oneOrNone(
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
        WHERE c.id = $2
        ${lockClause}`,
      [userId, conversationId],
    );
    return row as ConversationAccess | null;
  }

  async function hasConversationPermission(
    userId: string,
    conversationId: string,
    permission: ConversationPermission,
    options: AclQueryOptions = {},
  ): Promise<boolean> {
    if (!conversationMemberAllows(permission)) return false;
    return (await getConversationAccess(userId, conversationId, options)) !== null;
  }

  async function canCreateConversation(
    userId: string,
    groupId: string,
    memberIds: string[],
    options: AclQueryOptions = {},
  ): Promise<boolean> {
    const db = options.executor ?? app.db;
    if (
      !(await hasGroupPermission(
        userId,
        groupId,
        'conversation:create',
        options,
      ))
    ) {
      return false;
    }

    const expectedMembers = [...new Set([userId, ...memberIds])].sort();
    const lockClause = options.lock ? 'FOR SHARE OF ug' : '';
    const rows = await db.any(
      `SELECT ug.user_id AS "userId"
         FROM user_groups ug
        WHERE ug.group_id = $1
          AND ug.user_id = ANY($2::uuid[])
        ORDER BY ug.user_id
        ${lockClause}`,
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
    options: AclQueryOptions = {},
  ): Promise<boolean> {
    const db = options.executor ?? app.db;
    const access = await getConversationAccess(
      senderUserId,
      conversationId,
      options,
    );
    if (
      access === null ||
      access.groupId !== groupId ||
      !conversationMemberAllows('message:send')
    ) {
      return false;
    }

    const senderLockClause = options.lock ? 'FOR SHARE OF gdk' : '';
    const senderDevice = await db.oneOrNone(
      `SELECT 1
         FROM group_device_keys gdk
        WHERE gdk.group_id = $1
          AND gdk.user_id = $2
          AND gdk.device_id = $3
          AND gdk.status = 'active'
        ${senderLockClause}`,
      [groupId, senderUserId, senderDeviceId],
    );
    if (!senderDevice) return false;

    const expectedRecipients = [
      ...new Map(
        recipients.map((recipient) => [
          `${recipient.userId}\u0000${recipient.deviceId}`,
          recipient,
        ]),
      ).values(),
    ].sort((left, right) =>
      left.userId.localeCompare(right.userId) ||
      left.deviceId.localeCompare(right.deviceId));
    if (expectedRecipients.length === 0) return false;

    const recipientLockClause = options.lock
      ? 'FOR SHARE OF c, cu, ug, gdk'
      : '';
    const rows = await db.any(
      `SELECT expected.user_id AS "userId",
              expected.device_id AS "deviceId"
         FROM unnest($3::uuid[], $4::text[])
              AS expected(user_id, device_id)
         JOIN conversation_users cu
           ON cu.conversation_id = $1
          AND cu.user_id = expected.user_id
         JOIN conversations c
           ON c.id = cu.conversation_id
          AND c.group_id = $2
         JOIN user_groups ug
           ON ug.group_id = c.group_id
          AND ug.user_id = expected.user_id
         JOIN group_device_keys gdk
           ON gdk.group_id = c.group_id
          AND gdk.user_id = expected.user_id
          AND gdk.device_id = expected.device_id
          AND gdk.status = 'active'
        ORDER BY expected.user_id, expected.device_id
        ${recipientLockClause}`,
      [
        conversationId,
        groupId,
        expectedRecipients.map(({ userId }) => userId),
        expectedRecipients.map(({ deviceId }) => deviceId),
      ],
    );
    const actualRecipients = new Set(
      rows.map((row: any) => `${row.userId}\u0000${row.deviceId}`),
    );
    return expectedRecipients.every((recipient) =>
      actualRecipients.has(`${recipient.userId}\u0000${recipient.deviceId}`));
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

  async function markConversationRead(
    convId: string,
    userId: string,
    executor: DbExecutor = app.db,
  ) {
    const row = await executor.oneOrNone(
      `WITH authorized AS MATERIALIZED (
         SELECT cu.conversation_id, cu.user_id
           FROM conversation_users cu
           JOIN conversations c ON c.id = cu.conversation_id
           JOIN groups g ON g.id = c.group_id
           JOIN user_groups ug
             ON ug.group_id = c.group_id
            AND ug.user_id = cu.user_id
          WHERE cu.conversation_id = $1
            AND cu.user_id = $2
          FOR UPDATE OF cu
          FOR SHARE OF c, g, ug
       )
       UPDATE conversation_users target
          SET last_read_at = NOW()
         FROM authorized
        WHERE target.conversation_id = authorized.conversation_id
          AND target.user_id = authorized.user_id
        RETURNING target.last_read_at`,
      [convId, userId],
    );
    return (row?.last_read_at as string | undefined) ?? null;
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
