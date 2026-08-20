/*!
 * Local Hardware Agent — Client SDK
 * Browser-friendly. Use as ES module (import) or plain <script> (global `HardwareAgent`).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.HardwareAgent = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const DEFAULT_OPTIONS = {
    host: '127.0.0.1',
    wsPort: 8080,
    wssPort: 8443,
    httpPort: 8180,
    httpsPort: 8181,
    secure: false,
    token: null,
    autoReconnect: true,
    reconnectDelayMs: 2000,
    requestTimeoutMs: 30000,
    transport: 'ws'
  };

  class HardwareAgentClient {
    constructor(options = {}) {
      this.options = Object.assign({}, DEFAULT_OPTIONS, options);
      this._ws = null;
      this._connected = false;
      this._pending = new Map();
      this._listeners = { open: [], close: [], error: [], event: [] };
      this._closedByUser = false;
    }

    on(event, cb) {
      if (this._listeners[event]) this._listeners[event].push(cb);
      return this;
    }

    _emit(event, payload) {
      (this._listeners[event] || []).forEach((cb) => {
        try { cb(payload); } catch (_) {}
      });
    }

    _wsUrl() {
      const proto = this.options.secure ? 'wss' : 'ws';
      const port = this.options.secure ? this.options.wssPort : this.options.wsPort;
      return `${proto}://${this.options.host}:${port}`;
    }

    _httpUrl(pathname) {
      const proto = this.options.secure ? 'https' : 'http';
      const port = this.options.secure ? this.options.httpsPort : this.options.httpPort;
      return `${proto}://${this.options.host}:${port}${pathname}`;
    }

    connect() {
      if (this.options.transport !== 'ws') return Promise.resolve();
      return new Promise((resolve, reject) => {
        if (this._connected) return resolve();
        this._closedByUser = false;
        try {
          this._ws = new WebSocket(this._wsUrl());
        } catch (err) {
          return reject(err);
        }

        this._ws.onopen = async () => {
          this._connected = true;
          if (this.options.token) {
            try {
              await this._sendWs({ action: 'agent.auth', params: { token: this.options.token } });
            } catch (err) {
              this._emit('error', err);
              this._ws.close();
              return reject(err);
            }
          }
          this._emit('open');
          resolve();
        };

        this._ws.onmessage = (evt) => {
          let msg;
          try { msg = JSON.parse(evt.data); } catch (_) { return; }
          if (msg && msg.event) return this._emit('event', msg);
          if (msg && msg.id && this._pending.has(msg.id)) {
            const { resolve: r, reject: j, timer } = this._pending.get(msg.id);
            clearTimeout(timer);
            this._pending.delete(msg.id);
            return msg.ok ? r(msg.data) : j(Object.assign(new Error(msg.error && msg.error.message), { code: msg.error && msg.error.code }));
          }
        };

        this._ws.onerror = (err) => this._emit('error', err);
        this._ws.onclose = () => {
          this._connected = false;
          this._emit('close');
          if (this.options.autoReconnect && !this._closedByUser) {
            setTimeout(() => this.connect().catch(() => {}), this.options.reconnectDelayMs);
          }
        };
      });
    }

    close() {
      this._closedByUser = true;
      if (this._ws) this._ws.close();
    }

    _sendWs(payload) {
      return new Promise((resolve, reject) => {
        if (!this._connected || !this._ws) return reject(new Error('WebSocket not connected'));
        const id = payload.id || this._makeId();
        const timer = setTimeout(() => {
          this._pending.delete(id);
          reject(new Error(`Timeout waiting for ${payload.action}`));
        }, this.options.requestTimeoutMs);
        this._pending.set(id, { resolve, reject, timer });
        try {
          this._ws.send(JSON.stringify(Object.assign({}, payload, { id })));
        } catch (err) {
          clearTimeout(timer);
          this._pending.delete(id);
          reject(err);
        }
      });
    }

    async _sendHttp(action, params) {
      const headers = { 'Content-Type': 'application/json' };
      if (this.options.token) headers['X-Agent-Token'] = this.options.token;
      const resp = await fetch(this._httpUrl('/rpc'), {
        method: 'POST',
        headers,
        body: JSON.stringify({ id: this._makeId(), action, params })
      });
      const body = await resp.json();
      if (!body.ok) {
        const err = new Error(body.error && body.error.message);
        err.code = body.error && body.error.code;
        throw err;
      }
      return body.data;
    }

    async call(action, params) {
      if (this.options.transport === 'http') return this._sendHttp(action, params);
      if (!this._connected) await this.connect();
      const res = await this._sendWs({ action, params });
      return res;
    }

    _makeId() {
      return 'req_' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    }

    // High-level API
    ping() { return this.call('agent.ping'); }
    info() { return this.call('agent.info'); }
    getNetworkInfo() { return this.call('network.getInfo'); }
    getPrinters() { return this.call('printers.list'); }

    /**
     * Send RAW bytes to a printer (ESC/POS, ZPL, EPL).
     * @param {string} printerName - As returned by getPrinters()
     * @param {string|ArrayBuffer|Uint8Array} data - String, Base64, or binary
     * @param {object} [options] - { encoding: 'utf8'|'base64'|'hex', transport, host, port }
     */
    printRaw(printerName, data, options = {}) {
      let payload = data;
      let encoding = options.encoding || 'utf8';
      if (data instanceof ArrayBuffer || (typeof Uint8Array !== 'undefined' && data instanceof Uint8Array)) {
        payload = base64FromBytes(data instanceof Uint8Array ? data : new Uint8Array(data));
        encoding = 'base64';
      }
      return this.call('printers.printRaw', { printerName, data: payload, encoding, ...options });
    }

    /**
     * Print an image (PNG/JPG/Base64).
     * @param {string} printerName
     * @param {string|ArrayBuffer|Uint8Array|File|Blob} image
     * @param {object} [options] - { format: 'spooler'|'escpos'|'zpl', widthDots, threshold }
     */
    async printImage(printerName, image, options = {}) {
      const base64 = await imageToBase64(image);
      return this.call('printers.printImage', { printerName, image: base64, ...options });
    }
  }

  function base64FromBytes(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
    return typeof btoa !== 'undefined' ? btoa(binary) : Buffer.from(binary, 'binary').toString('base64');
  }

  async function imageToBase64(image) {
    if (typeof image === 'string') return image;
    if (image instanceof ArrayBuffer) return base64FromBytes(new Uint8Array(image));
    if (typeof Uint8Array !== 'undefined' && image instanceof Uint8Array) return base64FromBytes(image);
    if (typeof Blob !== 'undefined' && image instanceof Blob) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).replace(/^data:image\/[a-zA-Z+]+;base64,/, ''));
        reader.onerror = reject;
        reader.readAsDataURL(image);
      });
    }
    throw new Error('Unsupported image input');
  }

  return {
    Client: HardwareAgentClient,
    create(options) { return new HardwareAgentClient(options); }
  };
});
