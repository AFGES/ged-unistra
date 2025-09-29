import express, { Request, Response, NextFunction } from 'express';
import { createProxyMiddleware } from 'http-proxy-middleware';
import { CASAuthenticator } from './cas-authenticator';
import { AuthCredentials, WebDAVProxyConfig } from './types';

const app = express();

// Configuration via variables d'environnement avec valeurs par défaut
const config: WebDAVProxyConfig = {
    casLoginUrl: process.env.CAS_LOGIN_URL || 'https://cas.unistra.fr/cas/login?service=https%3A%2F%2Fged.unistra.fr%2Fnuxeo%2Fnxstartup.faces',
    webdavBaseUrl: process.env.WEBDAV_BASE_URL || 'https://ged.unistra.fr/nuxeo/site/dav',
    port: parseInt(process.env.PORT || '3000'),
    debugMode: process.env.DEBUG_MODE === 'true' || process.env.NODE_ENV === 'development'
};

// Instance de l'authenticateur CAS
const casAuthenticator = new CASAuthenticator(config.casLoginUrl, config.debugMode);

function debugLog(...args: any[]): void {
    if (config.debugMode) {
        console.log('[DEBUG]', new Date().toISOString(), ...args);
    }
}

// Parse des credentials depuis l'en-tête Authorization
function parseCredentials(authHeader: string): AuthCredentials | null {
    if (!authHeader?.startsWith('Basic ')) {
        return null;
    }
    
    try {
        const base64Credentials = authHeader.slice(6);
        const decodedCredentials = Buffer.from(base64Credentials, 'base64').toString('utf8');
        const [username, password] = decodedCredentials.split(':');
        
        if (!username || !password) {
            return null;
        }
        
        return { username, password };
    } catch (error) {
        debugLog('Erreur lors du décodage des credentials:', (error as Error).message);
        return null;
    }
}

// Middleware d'authentification
async function authenticate(req: Request, res: Response, next: NextFunction): Promise<void> {
    try {
        debugLog('Requête WebDAV reçue:', req.method, req.url);
        
        const authHeader = req.headers.authorization;
        
        if (!authHeader) {
            debugLog('Aucun en-tête Authorization, demande d\'authentification');
            res.status(401)
               .set('WWW-Authenticate', 'Basic realm="GED Unistra"')
               .send('Authentification requise');
            return;
        }
        
        const credentials = parseCredentials(authHeader);
        
        if (!credentials) {
            debugLog('Credentials invalides dans l\'en-tête Authorization');
            res.status(401)
               .set('WWW-Authenticate', 'Basic realm="GED Unistra"')
               .send('Credentials invalides');
            return;
        }
        
        debugLog('Tentative d\'authentification pour:', credentials.username);
        
        // Obtenir le cookie WebDAV via CAS
        const webdavCookie = await casAuthenticator.getWebDavCookie(credentials.username, credentials.password);
        
        debugLog('Cookie WebDAV obtenu:', webdavCookie);
        
        // Ajouter le cookie à la requête pour le proxy
        req.headers.cookie = webdavCookie;
        
        // Suppression de l'en-tête Authorization pour éviter de le transmettre au serveur WebDAV
        delete req.headers.authorization;
        
        console.log(`Utilisateur authentifié: ${credentials.username}`);
        next();
        
    } catch (error) {
        console.error('Erreur d\'authentification:', (error as Error).message);
        debugLog('Stack trace:', (error as Error).stack);
        
        res.status(500).json({ 
            error: 'Erreur interne du serveur',
            message: config.debugMode ? (error as Error).message : undefined
        });
    }
}

// Fonction pour transformer les réponses PROPFIND
function transformPropfindResponse(body: string): string {
    // Remplacer les URLs absolues par des chemins relatifs
    const baseUrlPattern = /https:\/\/ged\.unistra\.fr\/nuxeo\/site\/dav\//g;
    return body.replace(baseUrlPattern, '/');
}

// Configuration du proxy WebDAV avec transformation des réponses
const webdavProxy = createProxyMiddleware<Request, Response, NextFunction>({
    target: config.webdavBaseUrl,
    changeOrigin: true,
    selfHandleResponse: true, // Active la gestion manuelle des réponses
    on: {
        proxyRes: (proxyRes: any, req: Request, res: Response) => {
            // Interception des réponses PROPFIND pour modifier les href absolues en relatives
            if (req.method === 'PROPFIND' && proxyRes.headers['content-type']?.includes('application/xml')) {
                debugLog('Interception réponse PROPFIND pour transformation des URLs');
                
                let body = '';
                
                proxyRes.on('data', (chunk: Buffer) => {
                    body += chunk.toString('utf8');
                });
                
                proxyRes.on('end', () => {
                    try {
                        // Transformer les URLs absolues en relatives
                        const transformedBody = transformPropfindResponse(body);
                        
                        debugLog('Transformation XML:', {
                            original: body.substring(0, 200) + '...',
                            transformed: transformedBody.substring(0, 200) + '...'
                        });
                        
                        // Calculer et définir la nouvelle longueur du contenu
                        const contentLength = Buffer.byteLength(transformedBody, 'utf8');
                        res.setHeader('Content-Length', contentLength);
                        
                        debugLog('Content-Length mis à jour:', contentLength, 'bytes');
                        res.statusCode = proxyRes.statusCode || 200;
                        
                        // Envoyer la réponse transformée
                        res.end(transformedBody);
                        
                    } catch (error) {
                        debugLog('Erreur lors de la transformation XML:', (error as Error).message);
                        // En cas d'erreur, renvoyer la réponse originale avec les bons en-têtes
                        Object.keys(proxyRes.headers).forEach(key => {
                            const lowerKey = key.toLowerCase();
                            if (lowerKey !== 'transfer-encoding') {
                                const value = proxyRes.headers[key];
                                if (value) {
                                    res.setHeader(key, value);
                                }
                            }
                        });
                        res.statusCode = proxyRes.statusCode || 200;
                        res.end(body);
                    }
                });
            } else {
                // Pour les autres types de réponses, laisser le proxy gérer normalement
                Object.keys(proxyRes.headers).forEach(key => {
                    const value = proxyRes.headers[key];
                    if (value) {
                        res.setHeader(key, value);
                    }
                });
                res.statusCode = proxyRes.statusCode || 200;
                proxyRes.pipe(res);
            }
        },
        ...(config.debugMode && {
            error: (err: Error, req: Request, res: any) => {
                console.error('Erreur du proxy WebDAV:', err.message);
                debugLog('Détail de l\'erreur proxy:', err.stack);
                
                if (res && typeof res.headersSent !== 'undefined' && !res.headersSent && res.status) {
                    res.status(502).json({ 
                        error: 'Erreur du proxy WebDAV',
                        message: config.debugMode ? err.message : undefined
                    });
                }
            }
        })
    }
});

// Routes d'administration (sans authentification)
app.get('/admin/cache/stats', (req: Request, res: Response) => {
    try {
        const stats = casAuthenticator.getCacheStats();
        res.json({
            stats,
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Erreur lors de la récupération des stats:', (error as Error).message);
        res.status(500).json({ 
            error: 'Erreur lors de la récupération des statistiques',
            message: config.debugMode ? (error as Error).message : undefined
        });
    }
});

app.delete('/admin/cache/clear', (req: Request, res: Response) => {
    try {
        casAuthenticator.clearCache();
        console.log('Cache vidé via API admin');
        res.json({ 
            message: 'Cache vidé avec succès',
            timestamp: new Date().toISOString()
        });
    } catch (error) {
        console.error('Erreur lors de la suppression du cache:', (error as Error).message);
        res.status(500).json({ 
            error: 'Erreur lors de la suppression du cache',
            message: config.debugMode ? (error as Error).message : undefined
        });
    }
});

// Toutes les routes nécessitent une authentification obligatoire (sauf /admin/*)
app.use('/', authenticate, webdavProxy);

// Gestion d'erreur globale
app.use((error: Error, req: Request, res: Response, next: NextFunction) => {
    console.error('Erreur non gérée:', error.message);
    debugLog('Stack trace de l\'erreur non gérée:', error.stack);
    
    if (!res.headersSent) {
        res.status(500).json({
            error: 'Erreur interne du serveur',
            message: config.debugMode ? error.message : undefined,
            timestamp: new Date().toISOString()
        });
    }
});

// Démarrage du serveur
app.listen(config.port, () => {
    console.log(`🚀 Serveur WebDAV avec authentification CAS démarré sur http://localhost:${config.port}`);
    console.log(`📁 Proxy vers: ${config.webdavBaseUrl}`);
    console.log(`🔍 Mode debug: ${config.debugMode ? 'activé' : 'désactivé'}`);
    
    if (config.debugMode) {
        console.log('🛠️  Endpoints disponibles:');
        console.log('   - *    /*                    → Proxy WebDAV (AUTHENTIFICATION OBLIGATOIRE)');
        console.log('   - GET  /admin/cache/stats    → Statistiques du cache');
        console.log('   - DEL  /admin/cache/clear    → Vider le cache');
    }
});

// Gestion propre de l'arrêt
process.on('SIGTERM', () => {
    console.log('🛑 Arrêt du serveur WebDAV...');
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('\n🛑 Arrêt du serveur WebDAV...');
    process.exit(0);
});