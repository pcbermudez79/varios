#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const forge = require('node-forge');

const outDir = path.join(__dirname, '..', 'certs');
fs.mkdirSync(outDir, { recursive: true });

const keys = forge.pki.rsa.generateKeyPair(2048);
const cert = forge.pki.createCertificate();
cert.publicKey = keys.publicKey;
cert.serialNumber = Date.now().toString(16);
cert.validity.notBefore = new Date();
cert.validity.notAfter = new Date();
cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 5);

const attrs = [
  { name: 'commonName', value: 'localhost' },
  { name: 'organizationName', value: 'Local Hardware Agent' },
  { shortName: 'OU', value: 'Local Dev' }
];
cert.setSubject(attrs);
cert.setIssuer(attrs);
cert.setExtensions([
  { name: 'basicConstraints', cA: true },
  { name: 'keyUsage', keyCertSign: true, digitalSignature: true, keyEncipherment: true },
  { name: 'extKeyUsage', serverAuth: true, clientAuth: true },
  {
    name: 'subjectAltName',
    altNames: [
      { type: 2, value: 'localhost' },
      { type: 7, ip: '127.0.0.1' },
      { type: 7, ip: '::1' }
    ]
  }
]);
cert.sign(keys.privateKey, forge.md.sha256.create());

fs.writeFileSync(path.join(outDir, 'agent.key'), forge.pki.privateKeyToPem(keys.privateKey));
fs.writeFileSync(path.join(outDir, 'agent.crt'), forge.pki.certificateToPem(cert));

console.log('Certificates generated in', outDir);
console.log('Import agent.crt into your OS trust store to avoid browser warnings on wss://localhost.');
