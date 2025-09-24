# Multi-stage Dockerfile pour WebDAV Proxy avec CAS Auth
# Stage 1: Build stage avec Node.js complet
FROM node:20-alpine AS builder

# Métadonnées
LABEL maintainer="Charles Lesecq"
LABEL description="WebDAV Proxy with CAS Authentication - Build Stage"

# Définir le répertoire de travail
WORKDIR /app

# Installer pnpm globalement
RUN npm install -g pnpm

# Copier les fichiers de configuration des dépendances
COPY package.json pnpm-lock.yaml ./

# Installer les dépendances (y compris devDependencies pour le build)
RUN pnpm install --frozen-lockfile

# Copier le code source et les fichiers de configuration
COPY tsconfig.json ./
COPY src/ ./src/

# Compiler TypeScript vers JavaScript
RUN pnpm run build

# Installer seulement les dépendances de production
RUN pnpm install --prod --frozen-lockfile

# Stage 2: Runtime stage avec image distroless
FROM gcr.io/distroless/nodejs20-debian12:nonroot AS runtime

# Métadonnées pour l'image finale
LABEL maintainer="Charles Lesecq"
LABEL description="WebDAV Proxy with CAS Authentication - Production Runtime"
LABEL version="0.1.0"

# Définir le répertoire de travail
WORKDIR /app

# Copier les dépendances de production depuis le builder
COPY --from=builder /app/node_modules ./node_modules

# Copier le code JavaScript compilé
COPY --from=builder /app/dist ./dist

# Copier package.json pour les métadonnées
COPY --from=builder /app/package.json ./

# Exposer le port de l'application
EXPOSE 3000

# Variables d'environnement par défaut
ENV NODE_ENV=production
ENV PORT=3000

# Healthcheck pour vérifier que l'application fonctionne
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "require('http').get('http://localhost:3000/admin/cache/stats', (res) => { process.exit(res.statusCode === 200 ? 0 : 1) }).on('error', () => process.exit(1))"]

# Utiliser l'utilisateur non-root par défaut de distroless
USER nonroot

# Commande de démarrage
CMD ["dist/server.js"]