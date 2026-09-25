#!/usr/bin/env node
'use strict';

const logger = require('./utils/logger');
const config = require('./config');
const ws = require('./server/wsServer');
const http = require('./server/httpServer');

function bootstrap() {
  logger.info(`Starting Local Hardware Agent v${require('../package.json').version}`);
  logger.info(`Platform: ${process.platform} (${process.arch}) — Node ${process.version}`);
  logger.info(`Allowed origins: ${config.security.allowedOrigins.join(', ')}`);
  if (config.security.apiToken) {
    logger.info('API token required for all requests.');
  } else {
    logger.warn('API token NOT configured. Any allowed-origin page can call the agent.');
  }

  ws.start();
  http.start();

  process.on('SIGINT', () => {
    logger.info('SIGINT received. Shutting down.');
    process.exit(0);
  });
  process.on('SIGTERM', () => {
    logger.info('SIGTERM received. Shutting down.');
    process.exit(0);
  });
  process.on('unhandledRejection', (err) => logger.error('Unhandled rejection:', err));
  process.on('uncaughtException', (err) => logger.error('Uncaught exception:', err));
}

bootstrap();
