'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const config = require('../config');
const logger = require('../utils/logger');
const { dispatch } = require('./router');
const { isOriginAllowed, checkAuthToken } = require('./security');

function loadTls() {
  try {
    const key = fs.readFileSync(path.join(config.paths.certDir, 'agent.key'));
    const cert = fs.readFileSync(path.join(config.paths.certDir, 'agent.crt'));
    return { key, cert };
  } catch (err) {
    return null;
  }
}

function createUnderlyingServer() {
  const tls = config.server.useTls ? loadTls() : null;
  if (config.server.useTls && !tls) {
    logger.warn('TLS enabled but certificates not found. Falling back to plain WS.');
  }
  if (tls) return { server: https.createServer(tls), secure: true };
  return { server: http.createServer(), secure: false };
}

function start() {
  const { server, secure } = createUnderlyingServer();
  const port = secure ? config.server.wssPort : config.server.wsPort;

  const wss = new WebSocketServer({
    server,
    maxPayload: config.security.maxPayloadBytes,
    verifyClient: (info, cb) => {
      const origin = info.origin || info.req.headers.origin;
      if (!isOriginAllowed(origin)) {
        logger.warn(`Rejected WS from origin: ${origin}`);
        return cb(false, 403, 'Origin not allowed');
      }
      cb(true);
    }
  });

  wss.on('connection', (ws, req) => {
    const remote = req.socket.remoteAddress;
    let authed = !config.security.apiToken;

    logger.info(`WS client connected: ${remote} (authRequired=${!authed})`);

    ws.on('message', async (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch (err) {
        return ws.send(JSON.stringify({ ok: false, error: { code: 'BAD_JSON', message: err.message } }));
      }

      if (!authed) {
        if (msg.action === 'agent.auth' && checkAuthToken(msg.params && msg.params.token)) {
          authed = true;
          return ws.send(JSON.stringify({ id: msg.id, ok: true, action: 'agent.auth', data: { authed: true } }));
        }
        return ws.send(
          JSON.stringify({
            id: msg.id,
            ok: false,
            error: { code: 'UNAUTHORIZED', message: 'Authentication required. Send { action: "agent.auth", params: { token } } first.' }
          })
        );
      }

      const response = await dispatch(msg);
      ws.send(JSON.stringify(response));
    });

    ws.on('close', () => logger.info(`WS client disconnected: ${remote}`));
    ws.on('error', (err) => logger.error(`WS error: ${err.message}`));

    ws.send(
      JSON.stringify({
        event: 'welcome',
        secure,
        authRequired: !!config.security.apiToken,
        version: require('../../package.json').version
      })
    );
  });

  server.listen(port, config.server.host, () => {
    logger.info(`${secure ? 'WSS' : 'WS'} server listening on ${secure ? 'wss' : 'ws'}://${config.server.host}:${port}`);
  });

  return { server, wss };
}

module.exports = { start };
