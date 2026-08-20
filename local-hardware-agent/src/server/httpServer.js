'use strict';

const express = require('express');
const cors = require('cors');
const https = require('https');
const fs = require('fs');
const path = require('path');

const config = require('../config');
const logger = require('../utils/logger');
const { dispatch, actions } = require('./router');
const { isOriginAllowed, checkAuthToken } = require('./security');

function tokenGuard(req, res, next) {
  if (!config.security.apiToken) return next();
  const header = req.headers['x-agent-token'] || (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (checkAuthToken(header)) return next();
  return res.status(401).json({ ok: false, error: { code: 'UNAUTHORIZED', message: 'Invalid or missing token' } });
}

function build() {
  const app = express();

  app.use(
    cors({
      origin: (origin, cb) => (isOriginAllowed(origin) ? cb(null, true) : cb(new Error('Origin not allowed'))),
      methods: ['GET', 'POST', 'OPTIONS'],
      allowedHeaders: ['Content-Type', 'Authorization', 'X-Agent-Token'],
      credentials: false
    })
  );
  app.use(express.json({ limit: config.security.maxPayloadBytes }));

  app.get('/health', (_, res) => res.json({ ok: true, ts: Date.now(), actions }));

  app.post('/rpc', tokenGuard, async (req, res) => {
    const response = await dispatch(req.body);
    res.status(response.ok ? 200 : 400).json(response);
  });

  app.get('/actions', tokenGuard, (_, res) => res.json({ ok: true, data: actions }));

  app.use((err, _req, res, _next) => {
    logger.error('HTTP error:', err.message);
    res.status(500).json({ ok: false, error: { code: 'INTERNAL', message: err.message } });
  });

  return app;
}

function start() {
  const app = build();
  const httpServer = app.listen(config.server.httpPort, config.server.host, () => {
    logger.info(`HTTP server listening on http://${config.server.host}:${config.server.httpPort}`);
  });

  let httpsServer = null;
  if (config.server.useTls) {
    try {
      const key = fs.readFileSync(path.join(config.paths.certDir, 'agent.key'));
      const cert = fs.readFileSync(path.join(config.paths.certDir, 'agent.crt'));
      httpsServer = https.createServer({ key, cert }, app).listen(config.server.httpsPort, config.server.host, () => {
        logger.info(`HTTPS server listening on https://${config.server.host}:${config.server.httpsPort}`);
      });
    } catch (err) {
      logger.warn(`TLS certs not available (${err.message}). HTTPS server not started.`);
    }
  }

  return { app, httpServer, httpsServer };
}

module.exports = { start, build };
