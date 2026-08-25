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
