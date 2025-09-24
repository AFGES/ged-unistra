export interface AuthCredentials {
    username: string;
    password: string;
}

export interface CachedAuthData {
    jsessionid: string;
    username: string;
    passwordHash: string;
    timestamp: string;
}

export interface CsrfTokenResponse {
    execution: string;
    cookies: string[];
}

import { Request } from 'express';

export interface AuthenticatedRequest extends Request {
    auth?: {
        username: string;
        password: string;
        cookies: string;
    };
}

export interface CASConfig {
    loginUrl: string;
    debugMode: boolean;
}

export interface WebDAVProxyConfig {
    casLoginUrl: string;
    webdavBaseUrl: string;
    port: number;
    debugMode: boolean;
}