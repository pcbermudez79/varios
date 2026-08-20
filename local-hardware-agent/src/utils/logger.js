'use strict';

const levels = { debug: 10, info: 20, warn: 30, error: 40 };
const current = levels[(process.env.AGENT_LOG_LEVEL || 'info').toLowerCase()] || levels.info;

function fmt(level, args) {
  const ts = new Date().toISOString();
  return [`[${ts}]`, `[${level.toUpperCase()}]`, ...args];
}

module.exports = {
  debug: (...a) => levels.debug >= current && console.log(...fmt('debug', a)),
  info: (...a) => levels.info >= current && console.log(...fmt('info', a)),
  warn: (...a) => levels.warn >= current && console.warn(...fmt('warn', a)),
  error: (...a) => levels.error >= current && console.error(...fmt('error', a))
};
