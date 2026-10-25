# GED Unistra — Proxy WebDAV CAS

[English](README.md) | **Français**

Un petit reverse proxy [OpenResty](https://openresty.org/) (nginx + Lua) placé
devant l'endpoint WebDAV de la GED Unistra ([Nuxeo](https://www.nuxeo.com/)) et
qui effectue l'authentification [CAS](https://www.unistra.fr/) de façon
transparente pour le compte des clients WebDAV.

Les clients WebDAV standards (GVFS, Explorateur Windows, Finder macOS, davfs2, …)
ne parlent que l'authentification HTTP Basic — ils ne savent pas suivre un flux
de connexion CAS. Ce proxy accepte le Basic Auth, exécute la connexion CAS à la
place de l'utilisateur, met en cache la session obtenue, puis transmet les
requêtes au backend avec le bon cookie.

> Il s'agit d'une réécriture d'une implémentation Node.js antérieure.

## Fonctionnement

```
client WebDAV ──Basic Auth──▶ proxy ──connexion CAS──▶ cas.unistra.fr
                                │
                                │  injection du cookie JSESSIONID
                                ▼
                       ged.unistra.fr/nuxeo/site/dav/
```

1. Le client envoie un en-tête HTTP Basic `Authorization`.
2. Le proxy décode les identifiants et exécute le flux complet de connexion CAS
   pour obtenir un `JSESSIONID` Nuxeo.
3. Le `JSESSIONID` est mis en cache, l'en-tête `Authorization` est supprimé, et
   un `Cookie: JSESSIONID=…` est injecté.
4. La requête est transmise à `https://ged.unistra.fr/nuxeo/site/dav/`.

Les en-têtes `Set-Cookie` du backend sont supprimés afin que les cookies de
session ne soient jamais exposés au client WebDAV.

## Architecture / flux d'une requête

L'ensemble du flux se trouve dans [`nginx/nginx.conf`](nginx/nginx.conf) et les
modules Lua sous [`lua/`](lua/) :

| Phase | Module | Rôle |
|-------|--------|------|
| `access_by_lua` | `webdav_proxy.authenticate` | Valide le Basic Auth, exécute CAS, remplace `Authorization` → `Cookie` (401 en cas d'échec) |
| `proxy_pass` | nginx | Transmet vers l'upstream `ged_backend` (`ged.unistra.fr:443`, keepalive 32) en TLS vérifié |
| `header_filter_by_lua` | `webdav_proxy.rewrite_response_headers` | Supprime le `Set-Cookie` backend ; marque les PROPFIND pour réécriture du corps ; désactive le buffering pour les autres méthodes (streaming) |
| `body_filter_by_lua` | `webdav_proxy.rewrite_propfind_body` | Réécrit les URLs absolues du backend en chemins relatifs à la racine ; décode les `displayname` percent-encodés dans le XML PROPFIND |

**Flux CAS** ([`lua/cas_auth.lua`](lua/cas_auth.lua)) :
GET de la page de connexion → extraction du token `execution` → POST des
identifiants **sans suivre les redirections** → lecture du `JSESSIONID` dans
`Set-Cookie` (en suivant une `302` si le cookie n'est pas sur la réponse POST).
Si CAS répond par sa page de second facteur, le proxy POSTe un code TOTP
(`token`, nouvel `execution`, `_eventId_submit=Login`) avant de lire le
`JSESSIONID`. Une seule connexion CAS s'exécute à la fois par identifiants ; les
requêtes parallèles attendent son résultat.

**Cache de session** ([`lua/cache.lua`](lua/cache.lua)) : recherche cache-first
dans un `lua_shared_dict` de 10 Mo. La clé est
`cookies_<base64(identifiant)>_<sha256hex(motdepasse)>` ; la valeur est
`jsessionid|base64(identifiant)|timestamp`. TTL par défaut 3000 s (50 min),
éviction LRU lorsque le cache est plein.

## Endpoints

| Méthode | Chemin | Description |
|---------|--------|-------------|
| toute | `/` | Proxy WebDAV — Basic Auth requis |
| `GET` | `/health` | JSON de liveness (`{"status":"ok"}`), sans sonde backend |
| `GET` | `/admin/cache/stats` | Nombre de clés, capacité et octets libres du shared-dict |
| `DELETE` | `/admin/cache/clear` | Vide le cache de session (`405` pour toute autre méthode) |

## Configuration

Toute la configuration se fait par variables d'environnement (voir
[`.env.example`](.env.example) et [`lua/config.lua`](lua/config.lua)) :

| Variable | Défaut | Description |
|----------|--------|-------------|
| `CAS_LOGIN_URL` | `https://cas.unistra.fr/cas/login?service=…nxstartup.faces` | URL de connexion CAS (avec le paramètre service Nuxeo) |
| `WEBDAV_BASE_URL` | `https://ged.unistra.fr/nuxeo/site/dav` | Base WebDAV du backend ; le slash final est retiré. Sert à réécrire les URLs absolues des réponses PROPFIND |
| `AUTH_CACHE_TTL` | `3000` | TTL du cache de session, en secondes |
| `DEBUG_MODE` | `false` | Active les logs de debug `[cas-proxy]` |

## Lancement

### Avec Docker Compose

```bash
docker compose up --build
```

Le proxy écoute sur le port `80` du conteneur, mappé sur le port `3000` de
l'hôte (voir [`docker-compose.yml`](docker-compose.yml)). Le conteneur est limité
à 64 Mo / 0,5 CPU et tourne avec `no-new-privileges`.

### Image préconstruite (GHCR)

Les images sont construites et poussées par la CI
([`.github/workflows/build-container.yml`](.github/workflows/build-container.yml))
à chaque push sur `main` et sur les tags `v*` :

```bash
docker pull ghcr.io/afges/ged-unistra:latest
docker run -p 3000:80 ghcr.io/afges/ged-unistra:latest
```

Tags publiés : nom de branche, `sha-<commit>`, semver (`x.y.z`, `x.y`) sur les
tags, et `latest` sur la branche par défaut.

## Utilisation

Montez le proxy avec n'importe quel client WebDAV en utilisant vos identifiants
Unistra. Exemples :

```bash
# GIO / GVFS
gio mount dav://utilisateur@localhost:3000/

# davfs2
sudo mount -t davfs http://localhost:3000/ /mnt/ged
```

### Double authentification (A2F)

Le CAS Unistra peut demander un second facteur. Le proxy ne prend en charge que
la méthode **TOTP**, et génère lui-même les codes :

1. Activez la méthode TOTP dans le
   [gestionnaire A2F Unistra](https://cas-mfa.app.unistra.fr/). Il affiche un QR
   code et une suite de caractères : cette suite est votre secret TOTP.
2. Utilisez comme mot de passe WebDAV `motdepasse|SECRET` (secret après le
   dernier `|` ; espaces et casse ignorés).

Vous pouvez aussi fournir un code courant au lieu du secret :
`motdepasse|123456`. Le code est utilisé tel quel : la session ne dure que
jusqu'à l'expiration du cache (`AUTH_CACHE_TTL`) ; un nouveau code est ensuite
nécessaire.

Les comptes sans A2F continuent d'utiliser le mot de passe seul. Push, code par
courriel, grille de codes et WebAuthn ne sont pas pris en charge.

## Notes de sécurité

- **Placez du TLS devant ce proxy en production.** Il écoute en clair sur `:80`
  et accepte le Basic Auth : les identifiants circulent en clair tant que le TLS
  n'est pas terminé en amont (reverse proxy / ingress).
- Les identifiants sont envoyés à chaque requête. Le mot de passe n'est jamais
  stocké — seul son SHA-256 figure dans la clé de cache ; seul le `JSESSIONID`
  dérivé est mis en cache.
- Avec l'A2F, le proxy reçoit **les deux facteurs** (mot de passe et secret
  TOTP) à chaque requête. Ne l'exploitez que pour vous-même ou pour des
  utilisateurs qui font confiance à son opérateur, et uniquement derrière du TLS.
  Le secret n'est jamais stocké ni journalisé : il est haché dans la clé de cache
  avec le mot de passe.
- Les en-têtes `Set-Cookie` du backend ne sont jamais transmis au client.
- Le TLS vers l'upstream est vérifié (`proxy_ssl_verify on`, bundle CA système).

## Structure du projet

```
.
├── nginx/nginx.conf          # routes, upstream, hooks Lua
├── lua/
│   ├── config.lua            # config par variables d'env + défauts
│   ├── cas_auth.lua          # flux de connexion CAS (+ second facteur TOTP)
│   ├── totp.lua              # générateur de codes TOTP (RFC 6238)
│   ├── cache.lua             # cache de session (shared-dict)
│   ├── webdav_proxy.lua      # auth + réécriture PROPFIND/en-têtes
│   └── admin.lua             # /health + endpoints d'admin du cache
├── Dockerfile                # image OpenResty (opm lua-resty-http)
├── docker-compose.yml
└── .github/workflows/build-container.yml
```
