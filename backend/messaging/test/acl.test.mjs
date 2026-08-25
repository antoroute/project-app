import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CONVERSATION_MEMBER_PERMISSIONS,
  GROUP_ROLE_PERMISSIONS,
  conversationMemberAllows,
  groupRoleAllows,
  initAclService,
} from '../dist/services/acl.js';

const OWNER = '11111111-1111-4111-8111-111111111111';
const MEMBER = '22222222-2222-4222-8222-222222222222';
const OUTSIDER = '33333333-3333-4333-8333-333333333333';
const GROUP = '44444444-4444-4444-8444-444444444444';
const CONVERSATION = '55555555-5555-4555-8555-555555555555';

test('la matrice autorise seulement owner/admin à gérer les adhésions', () => {
  for (const permission of ['join-request:read', 'join-request:handle']) {
    assert.equal(groupRoleAllows('owner', permission), true);
    assert.equal(groupRoleAllows('admin', permission), true);
    assert.equal(groupRoleAllows('member', permission), false);
  }
});

test('seul owner peut affecter un rôle et aucun rôle ne peut voter', () => {
  assert.equal(groupRoleAllows('owner', 'member-role:set'), true);
  assert.equal(groupRoleAllows('admin', 'member-role:set'), false);
  assert.equal(groupRoleAllows('member', 'member-role:set'), false);
  for (const permissions of Object.values(GROUP_ROLE_PERMISSIONS)) {
    assert.equal(permissions.includes('join-request:vote'), false);
  }
});

test('tous les rôles ont les droits communs sans privilège de gestion implicite', () => {
  for (const role of ['owner', 'admin', 'member']) {
    for (const permission of [
      'group:read',
      'members:read',
      'keys:read',
      'keys:manage-own',
      'conversation:create',
    ]) {
      assert.equal(groupRoleAllows(role, permission), true);
    }
  }
});

test('un participant possède exactement les permissions conversation déclarées', () => {
  for (const permission of CONVERSATION_MEMBER_PERMISSIONS) {
    assert.equal(conversationMemberAllows(permission), true);
  }
  assert.deepEqual(CONVERSATION_MEMBER_PERMISSIONS, [
    'conversation:read',
    'message:read',
    'message:send',
    'read-receipt:write',
    'readers:read',
    'socket:subscribe',
    'typing:emit',
  ]);
});

test('la création refuse un participant extérieur avant que la route écrive', async () => {
  const app = {
    db: {
      oneOrNone: async () => ({ role: 'owner' }),
      any: async () => [{ userId: OWNER }, { userId: MEMBER }],
    },
  };
  const acl = initAclService(app);

  assert.equal(
    await acl.canCreateConversation(OWNER, GROUP, [MEMBER, OUTSIDER]),
    false,
  );
});

test('la création accepte uniquement un ensemble entièrement membre du cercle', async () => {
  const app = {
    db: {
      oneOrNone: async () => ({ role: 'owner' }),
      any: async () => [{ userId: OWNER }, { userId: MEMBER }],
    },
  };
  const acl = initAclService(app);

  assert.equal(await acl.canCreateConversation(OWNER, GROUP, [MEMBER]), true);
});

test('l’envoi transactionnel verrouille et valide tous les destinataires en une requête', async () => {
  const queryCalls = [];
  let oneOrNoneCalls = 0;
  const transaction = {
    oneOrNone: async (query) => {
      queryCalls.push(query);
      oneOrNoneCalls += 1;
      if (oneOrNoneCalls === 1) {
        return {
          conversationId: CONVERSATION,
          groupId: GROUP,
          groupRole: 'owner',
        };
      }
      return { active: true };
    },
    any: async (query) => {
      queryCalls.push(query);
      return [
        { userId: MEMBER, deviceId: 'member-a' },
        { userId: OUTSIDER, deviceId: 'outsider-a' },
      ];
    },
  };
  const app = {
    db: {
      oneOrNone: async () => {
        throw new Error('the pool executor must not be used');
      },
      any: async () => {
        throw new Error('the pool executor must not be used');
      },
    },
  };
  const acl = initAclService(app);

  const allowed = await acl.canSend(
    OWNER,
    'owner-a',
    GROUP,
    CONVERSATION,
    [
      { userId: MEMBER, deviceId: 'member-a' },
      { userId: OUTSIDER, deviceId: 'outsider-a' },
    ],
    { executor: transaction, lock: true },
  );

  assert.equal(allowed, true);
  assert.equal(queryCalls.length, 3);
  assert.match(queryCalls[0], /FOR SHARE OF c, cu, g, ug/);
  assert.match(queryCalls[1], /FOR SHARE OF gdk/);
  assert.match(queryCalls[2], /FROM unnest/);
  assert.match(queryCalls[2], /FOR SHARE OF c, cu, ug, gdk/);
});

test('l’accusé de lecture verrouille la participation avant la mise à jour', async () => {
  let capturedQuery = '';
  const transaction = {
    oneOrNone: async (query) => {
      capturedQuery = query;
      return { last_read_at: '2026-08-25T12:00:00.000Z' };
    },
  };
  const acl = initAclService({ db: {} });

  const timestamp = await acl.markConversationRead(
    CONVERSATION,
    OWNER,
    transaction,
  );

  assert.equal(timestamp, '2026-08-25T12:00:00.000Z');
  assert.match(capturedQuery, /FOR UPDATE OF cu/);
  assert.match(capturedQuery, /FOR SHARE OF c, g, ug/);
  assert.match(capturedQuery, /RETURNING target\.last_read_at/);
});
