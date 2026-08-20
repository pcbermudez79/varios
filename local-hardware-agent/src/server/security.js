'use strict';

const config = require('../config');

function isOriginAllowed(origin) {
  if (!origin) return true;
  const allowed = config.security.allowedOrigins;
  if (allowed.includes('*')) return true;
  return allowed.some((entry) => {
    if (entry === origin) return true;
    if (entry.startsWith('*.')) {
      const suffix = entry.slice(1);
      return origin.endsWith(suffix);
    }
    return false;
  });
}

function checkAuthToken(token) {
  if (!config.security.apiToken) return true;
  return token === config.security.apiToken;
}

function corsMiddleware(req, res, next) {
  const origin = req.headers.origin;
  if (origin && isOriginAllowed(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization,X-Agent-Token');
    res.setHeader('Access-Control-Max-Age', '600');
  }
  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    return res.end();
  }
  next();
}

module.exports = { isOriginAllowed, checkAuthToken, corsMiddleware };
