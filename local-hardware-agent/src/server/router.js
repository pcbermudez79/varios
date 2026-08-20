'use strict';

const network = require('../modules/network');
const printers = require('../modules/printers');
const logger = require('../utils/logger');

const handlers = {
  'agent.ping': async () => ({ pong: true, ts: Date.now() }),
  'agent.info': async () => ({
    name: 'local-hardware-agent',
    version: require('../../package.json').version,
    platform: process.platform,
    arch: process.arch,
    node: process.version
  }),
  'network.getInfo': async () => network.getNetworkInfo(),

  'printers.list': async () => printers.listPrinters(),

  'printers.printRaw': async (params) => {
    const { printerName, data, encoding, transport, host, port } = params || {};
    return printers.printRaw(printerName, data, { encoding, transport, host, port });
  },

  'printers.printImage': async (params) => {
    const { printerName, image, format, widthDots, threshold, cupsOptions, printerOptions } = params || {};
    return printers.printImage(printerName, image, {
      format,
      widthDots,
      threshold,
      cupsOptions,
      printerOptions
    });
  }
};

async function dispatch(message) {
  const { id, action, params } = message || {};
  if (!action || typeof action !== 'string') {
    return { id, ok: false, error: { code: 'BAD_REQUEST', message: 'action is required' } };
  }
  const handler = handlers[action];
  if (!handler) {
    return { id, ok: false, error: { code: 'UNKNOWN_ACTION', message: `Unknown action: ${action}` } };
  }
  try {
    const data = await handler(params);
    return { id, ok: true, action, data };
  } catch (err) {
    logger.error(`Handler ${action} failed:`, err);
    return {
      id,
      ok: false,
      action,
      error: { code: err.code || 'HANDLER_ERROR', message: err.message }
    };
  }
}

module.exports = { dispatch, actions: Object.keys(handlers) };
