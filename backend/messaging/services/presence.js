import { createClient } from 'redis';

const PRESENCE_TTL = 300; // TTL en secondes

export async function createPresenceService(redisUrl) {
  const client = createClient({ url: redisUrl });
  client.on('error', err => console.error('Redis presence error:', err));
  await client.connect();

  return {
    async addUser(conversationId, userId) {
      const key = `presence:${conversationId}`;
      await client.sAdd(key, userId);
      await client.expire(key, PRESENCE_TTL);
    },
    async removeUser(conversationId, userId) {
      const key = `presence:${conversationId}`;
      await client.sRem(key, userId);
    },
    async getActiveUsers(conversationId) {
      return await client.sMembers(`presence:${conversationId}`);
    }
  };
}