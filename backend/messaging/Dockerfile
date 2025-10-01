# ---- Builder (TS) ----
FROM node:20-slim AS builder
WORKDIR /app

# Copie des manifests d'abord (cache Docker)
COPY package*.json ./
# Installe les deps pour build (ci si lock, sinon install)
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Build TypeScript
COPY tsconfig.json ./
COPY src ./src
RUN node -v && npm -v \
 && echo '--- TREE ---' \
 && find src -maxdepth 3 -type f -print \
 && echo '--- BUILD ---'
RUN npm run build

# ---- Runner (prod) ----
FROM node:20-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3001

# Installe uniquement les deps prod (ci si lock, sinon install)
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

# Copie des fichiers compilés
COPY --from=builder /app/dist ./dist

EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3001)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
