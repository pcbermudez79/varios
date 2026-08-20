'use strict';

const path = require('path');
const os = require('os');

module.exports = {
  server: {
    host: '127.0.0.1',
    httpPort: 8180,
    httpsPort: 8181,
    wsPort: 8080,
    wssPort: 8443,
    useTls: process.env.AGENT_TLS === 'true'
  },
  security: {
    allowedOrigins: (process.env.AGENT_ALLOWED_ORIGINS || 'http://localhost,https://localhost,http://127.0.0.1,https://127.0.0.1')
      .split(',')
      .map((o) => o.trim())
      .filter(Boolean),
    apiToken: process.env.AGENT_API_TOKEN || null,
    maxPayloadBytes: 8 * 1024 * 1024
  },
  paths: {
    certDir: path.join(__dirname, '..', 'certs'),
    tempDir: path.join(os.tmpdir(), 'local-hardware-agent')
  },
  logging: {
    level: process.env.AGENT_LOG_LEVEL || 'info'
  }
};
