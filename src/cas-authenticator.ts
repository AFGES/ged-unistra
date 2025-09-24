import NodeCache from 'node-cache';
import { AuthCredentials, CachedAuthData, CsrfTokenResponse } from './types';
const crypto = require('crypto');

export class CASAuthenticator {
    private casLoginUrl: string;
    private debugMode: boolean;
    private cookieCache: NodeCache;

    constructor(casLoginUrl: string, debugMode: boolean = false) {
        this.casLoginUrl = casLoginUrl;
        this.debugMode = debugMode;
        this.cookieCache = new NodeCache({ stdTTL: 3600 });
    }

    private debugLog(...args: any[]): void {
        if (this.debugMode) {
            console.log('[DEBUG]', new Date().toISOString(), ...args);
        }
    }

    // Déduplicater et normaliser les cookies
    private deduplicateCookies(cookies: string[]): string {
        const cookieMap = new Map<string, string>();
        
        for (const cookie of cookies) {
            if (!cookie) continue;
            
            const cookiePart = cookie.split(';')[0]; // Prendre seulement name=value
            if (!cookiePart) continue;
            
            const [name, value] = cookiePart.split('=');
            if (name && value) {
                cookieMap.set(name.trim().toLowerCase(), `${name.trim()}=${value.trim()}`);
            }
        }
        
        const result = Array.from(cookieMap.values()).join('; ');
        this.debugLog('Cookies dédupliqués:', result);
        return result;
    }

    // Extraire le token CSRF depuis le HTML avec regex
    private extractExecutionToken(html: string): string | null {
        // Chercher le token execution dans un input caché
        const patterns = [
            /<input[^>]*name=["']execution["'][^>]*value=["']([^"']+)["'][^>]*>/i,
            /<input[^>]*value=["']([^"']+)["'][^>]*name=["']execution["'][^>]*>/i
        ];
        
        for (const pattern of patterns) {
            const match = html.match(pattern);
            if (match && match[1]) {
                this.debugLog('Token execution trouvé avec regex:', match[1]);
                return match[1];
            }
        }
        
        this.debugLog('Token execution non trouvé dans le HTML');
        return null;
    }

    // Extraire JSESSIONID depuis l'URL
    extractJSessionId(url: string): string | null {
        const match = url.match(/;jsessionid=([^?&;]+)/);
        if (match) {
            this.debugLog('JSESSIONID extrait de l\'URL:', match[1]);
            return match[1];
        }
        this.debugLog('Aucun JSESSIONID trouvé dans l\'URL:', url);
        return null;
    }

    // Extraire JSESSIONID depuis les cookies
    extractJSessionIdFromCookies(cookies: string[]): string | null {
        for (const cookie of cookies) {
            if (cookie && cookie.toLowerCase().startsWith('jsessionid=')) {
                const value = cookie.split('=')[1]?.split(';')[0];
                if (value) {
                    this.debugLog('JSESSIONID extrait des cookies:', value);
                    return value;
                }
            }
        }
        return null;
    }

    // Obtenir le token CSRF
    async getCsrfToken(): Promise<CsrfTokenResponse> {
        this.debugLog('Récupération du token CSRF depuis', this.casLoginUrl);
        
        const response = await fetch(this.casLoginUrl, {
            method: 'GET',
            redirect: 'follow'
        });
        
        if (!response.ok) {
            throw new Error(`Erreur HTTP ${response.status}: ${response.statusText}`);
        }
        
        const html = await response.text();
        
        const execution = this.extractExecutionToken(html);
        if (!execution) {
            throw new Error('Token CSRF (execution) non trouvé');
        }
        
        this.debugLog('Token CSRF trouvé:', execution);
        
        // Extraire les cookies depuis les headers Set-Cookie
        const setCookieHeaders = response.headers.getSetCookie ? 
            response.headers.getSetCookie() : 
            (response.headers.get('set-cookie') ? [response.headers.get('set-cookie')!] : []);
        
        return {
            execution,
            cookies: setCookieHeaders
        };
    }

    // Authentification simplifiée - retourne uniquement le JSESSIONID
    async authenticate(credentials: AuthCredentials): Promise<string> {
        this.debugLog('Début de l\'authentification CAS pour:', credentials.username);
        
        // 1. Récupérer le token CSRF
        const { execution, cookies: initialCookies } = await this.getCsrfToken();
        
        // 2. Préparer et envoyer les données de login
        const loginData = new URLSearchParams({
            username: credentials.username,
            password: credentials.password,
            execution,
            _eventId: 'submit',
            geolocation: ''
        });
        
        const cookieString = this.deduplicateCookies(initialCookies);
        
        const response = await fetch(this.casLoginUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Cookie': cookieString
            },
            body: loginData.toString(),
            redirect: 'manual' // Équivalent à maxRedirects: 0
        });
        
        this.debugLog('Réponse CAS reçue, status:', response.status);
        
        // 3. Chercher JSESSIONID dans les cookies de réponse
        const setCookieHeaders = response.headers.getSetCookie ? 
            response.headers.getSetCookie() : 
            (response.headers.get('set-cookie') ? [response.headers.get('set-cookie')!] : []);
        
        let jsessionid = this.extractJSessionIdFromCookies(setCookieHeaders);
        
        // 4. Si pas trouvé, suivre la redirection pour extraire de l'URL
        if (!jsessionid && response.status >= 300 && response.status < 400 && response.headers.get('location')) {
            // Combiner tous les cookies sans duplication
            const allCookies = [...initialCookies, ...setCookieHeaders];
            jsessionid = await this.getJSessionIdFromRedirection(response.headers.get('location')!, allCookies);
        }
        
        if (!jsessionid) {
            throw new Error('JSESSIONID non trouvé après authentification');
        }
        
        this.debugLog('JSESSIONID final obtenu:', jsessionid);
        return jsessionid;
    }

    // Obtenir JSESSIONID depuis une redirection
    private async getJSessionIdFromRedirection(redirectUrl: string, existingCookies: string[]): Promise<string | null> {
        this.debugLog('Redirection détectée vers:', redirectUrl);

        const cookieString = this.deduplicateCookies(existingCookies);

        try {
            const redirectResponse = await fetch(redirectUrl, {
                method: 'GET',
                headers: { 'Cookie': cookieString },
                redirect: 'follow' // Suit automatiquement jusqu'à 5 redirections
            });
            
            if (!redirectResponse.ok) {
                throw new Error(`Erreur HTTP ${redirectResponse.status}: ${redirectResponse.statusText}`);
            }
            
            const finalUrl = redirectResponse.url;
            this.debugLog('URL finale après redirection:', finalUrl);
            
            // Chercher JSESSIONID dans l'URL
            return this.extractJSessionId(finalUrl);
        } catch (error) {
            this.debugLog('Erreur lors de la redirection:', (error as Error).message);
            return null;
        }
    }

    // Créer une clé de cache sécurisée
    createCacheKey(username: string, password: string): string {
        const passwordHash = crypto.createHash('sha256').update(password).digest('hex');
        return `cookies_${Buffer.from(username).toString('base64')}_${passwordHash}`;
    }

    // Obtenir JSESSIONID avec cache
    async getCachedJSessionId(username: string, password: string): Promise<string> {
        const cacheKey = this.createCacheKey(username, password);
        const cachedData = this.cookieCache.get<CachedAuthData>(cacheKey);
        
        if (cachedData) {
            this.debugLog(`JSESSIONID récupéré du cache pour l'utilisateur: ${username} (${cachedData.jsessionid})`);
            return cachedData.jsessionid;
        }

        this.debugLog(`Authentification CAS pour l'utilisateur: ${username}`);
        const jsessionid = await this.authenticate({ username, password } as AuthCredentials);
        
        const dataToCache: CachedAuthData = {
            jsessionid,
            username,
            passwordHash: Buffer.from(password).toString('base64'),
            timestamp: new Date().toISOString()
        };
        
        this.cookieCache.set(cacheKey, dataToCache, 3000);
        console.log(`JSESSIONID mis en cache pour l'utilisateur: ${username}`);
        
        return jsessionid;
    }

    // Obtenir le cookie formaté pour WebDAV
    async getWebDavCookie(username: string, password: string): Promise<string> {
        const jsessionid = await this.getCachedJSessionId(username, password);
        return `JSESSIONID=${jsessionid}`;
    }

    // Vider le cache
    clearCache(): void {
        this.cookieCache.flushAll();
    }

    // Statistiques du cache
    getCacheStats(): NodeCache.Stats {
        return this.cookieCache.getStats();
    }
}