# WebDAV Proxy avec authentification CAS

Proxy WebDAV moderne avec authentification CAS pour l'Université de Strasbourg (Unistra), développé en TypeScript avec des solutions natives (sans dépendances externes lourdes).

## 🚀 Fonctionnalités

- **Proxy WebDAV sécurisé** : Proxification transparente vers GED Unistra
- **Authentification CAS** : Intégration avec le système CAS de l'université
- **Cache intelligent** : Mise en cache sécurisée des sessions avec vérification des mots de passe
- **API d'administration** : Endpoints pour gérer le cache et surveiller les statistiques
- **Mode debug** : Logging détaillé pour le développement et le débogage
- **TypeScript** : Code type-safe et moderne
- **Solutions natives** : Utilise fetch natif et parsing regex (pas d'axios ni cheerio)

## 📁 Structure du projet

```
proxy/
├── src/
│   ├── server.ts              # Serveur principal Express
│   ├── cas-authenticator.ts   # Classe d'authentification CAS
│   └── types/
│       └── index.ts           # Interfaces TypeScript
├── dist/                      # Code JavaScript compilé
├── package.json               # Configuration et dépendances
├── tsconfig.json             # Configuration TypeScript
└── README.md                 # Documentation
```

## 🛠️ Installation

### Prérequis
- Node.js (v16 ou supérieur)
- pnpm (gestionnaire de paquets recommandé)

### Installation des dépendances

```bash
pnpm install
```

## 🏃‍♂️ Utilisation

### Développement

```bash
# Démarrer en mode développement avec rechargement automatique
pnpm dev

# Démarrer en mode développement avec surveillance des fichiers
pnpm dev:watch
```

### Production

```bash
# Compiler le TypeScript
pnpm build

# Démarrer le serveur en production
pnpm start
```

Le serveur sera disponible sur `http://localhost:3000`.

## 🔧 Configuration

La configuration se trouve dans `src/server.ts` :

```typescript
const config: WebDAVProxyConfig = {
    casLoginUrl: 'https://cas.unistra.fr/cas/login?service=https%3A%2F%2Fged.unistra.fr%2Fnuxeo%2Fnxstartup.faces',
    webdavBaseUrl: 'https://ged.unistra.fr/nuxeo/site/dav/',
    port: 3000,
    debugMode: true
};
```

## 📡 Endpoints disponibles

### WebDAV
- `/*` : Toutes les requêtes WebDAV (nécessite authentification Basic)

### Administration
- `GET /` : Informations du serveur
- `GET /admin/cache/stats` : Statistiques du cache
- `DELETE /admin/cache/clear` : Vider le cache d'authentification

## 🔐 Authentification

Le proxy utilise l'authentification HTTP Basic. Les clients WebDAV doivent fournir :
- **Username** : Identifiant Unistra
- **Password** : Mot de passe Unistra

Le processus d'authentification :
1. Extraction des credentials depuis l'en-tête `Authorization`
2. Authentification via CAS Unistra
3. Récupération du JSESSIONID
4. Mise en cache sécurisée de la session
5. Transmission du cookie au serveur WebDAV cible

## 🏗️ Architecture

### CASAuthenticator
Classe principale gérant l'authentification CAS :
- Extraction des tokens CSRF avec parsing regex natif
- Gestion des redirections CAS
- Extraction et cache des JSESSIONID
- Vérification sécurisée des mots de passe

### Cache sécurisé
- Clés de cache basées sur hash des credentials
- TTL de 50 minutes (3000 secondes)
- Vérification de l'intégrité des mots de passe
- API d'administration pour surveillance et nettoyage

### Middleware d'authentification
- Parsing automatique des en-têtes Authorization
- Gestion d'erreurs avec réponses appropriées
- Logging détaillé en mode debug

## 🛡️ Sécurité

- **Hachage des mots de passe** : Les mots de passe sont hachés avant mise en cache
- **Validation des credentials** : Vérification de l'intégrité à chaque utilisation
- **TTL des sessions** : Expiration automatique des caches
- **Headers sécurisés** : Gestion propre des en-têtes d'authentification

## 🐛 Debug

Activer le mode debug dans la configuration pour obtenir des logs détaillés :

```typescript
debugMode: true
```

Les logs incluent :
- Étapes d'authentification CAS
- Extraction des tokens et cookies
- Requêtes et réponses du proxy
- Statistiques du cache

## 📦 Dépendances

### Production
- `express` : Serveur web
- `http-proxy-middleware` : Proxification WebDAV
- `node-cache` : Cache en mémoire

### Développement
- `typescript` : Compilation TypeScript
- `ts-node` : Exécution TypeScript directe
- `@types/*` : Définitions de types

## 🚀 Déploiement

1. Cloner le projet
2. Installer les dépendances : `pnpm install`
3. Compiler : `pnpm build`
4. Démarrer : `pnpm start`

## 🔄 Migration depuis la version JavaScript

Cette version TypeScript remplace complètement la version JavaScript précédente :

- ✅ **Axios → fetch natif** : Réduction des dépendances
- ✅ **Cheerio → regex natif** : Parsing HTML sans dépendances lourdes  
- ✅ **JavaScript → TypeScript** : Type safety et meilleure maintenabilité
- ✅ **Architecture modulaire** : Classes séparées et interfaces définies

## 📄 Licence

Projet développé pour l'Université de Strasbourg.