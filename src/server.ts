import express, { Request, Response, NextFunction } from 'express';
import { createProxyMiddleware } from 'http-proxy-middleware';
import { CASAuthenticator } from './cas-authenticator';
import { AuthCredentials, WebDAVProxyConfig } from './types';

const app = express();

// Configuration
const config: WebDAVProxyConfig = {
    casLoginUrl: 'https://cas.unistra.fr/cas/login?service=https%3A%2F%2Fged.unistra.fr%2Fnuxeo%2Fnxstartup.faces',
    webdavBaseUrl: 'https://ged.unistra.fr/nuxeo/site/dav/',
    port: 3000,
    debugMode: true
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
    if (!authHeader || !authHeader.startsWith('Basic ')) {
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
               .set('WWW-Authenticate', 'Basic realm="WebDAV"')
               .send('Authentification requise');
            return;
        }
        
        const credentials = parseCredentials(authHeader);
        
        if (!credentials) {
            debugLog('Credentials invalides dans l\'en-tête Authorization');
            res.status(401)
               .set('WWW-Authenticate', 'Basic realm="WebDAV"')
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

// Configuration du proxy WebDAV (http-proxy-middleware v3)
const webdavProxy = createProxyMiddleware({
    target: config.webdavBaseUrl,
    changeOrigin: true,
    // Configuration des événements directement dans les options (v3)
    ...(config.debugMode && {
        onError: (err: Error, req: Request, res: Response) => {
            console.error('Erreur du proxy WebDAV:', err.message);
            debugLog('Détail de l\'erreur proxy:', err.stack);
            
            if (!res.headersSent) {
                res.status(502).json({ 
                    error: 'Erreur du proxy WebDAV',
                    message: config.debugMode ? err.message : undefined
                });
            }
        }
    })
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