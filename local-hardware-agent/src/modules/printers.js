'use strict';

const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs/promises');
const path = require('path');
const os = require('os');
const net = require('net');
const { randomUUID } = require('crypto');

const execAsync = promisify(exec);
const logger = require('../utils/logger');
const config = require('../config');

const PLATFORM = process.platform;

async function ensureTempDir() {
  await fs.mkdir(config.paths.tempDir, { recursive: true });
  return config.paths.tempDir;
}

async function listPrintersWindows() {
  const ps =
    'Get-CimInstance Win32_Printer | Select-Object Name,DriverName,PortName,ShareName,Default,Local,Network,PrinterStatus | ConvertTo-Json -Compress';
  const { stdout } = await execAsync(`powershell -NoProfile -Command "${ps}"`, {
    windowsHide: true,
    maxBuffer: 4 * 1024 * 1024
  });
  const parsed = JSON.parse(stdout || '[]');
  const arr = Array.isArray(parsed) ? parsed : [parsed];
  return arr.map((p) => ({
    name: p.Name,
    driver: p.DriverName,
    port: p.PortName,
    share: p.ShareName || null,
    default: !!p.Default,
    local: !!p.Local,
    network: !!p.Network,
    status: p.PrinterStatus,
    connection: p.Network ? 'network' : 'local'
  }));
}

async function listPrintersCups() {
  try {
    const { stdout } = await execAsync('lpstat -e', { maxBuffer: 2 * 1024 * 1024 });
    const names = stdout.split('\n').map((s) => s.trim()).filter(Boolean);
    let defaultName = null;
    try {
      const { stdout: d } = await execAsync('lpstat -d');
      const m = d.match(/:\s*(.+)\s*$/);
      if (m) defaultName = m[1].trim();
    } catch (_) {}

    const results = await Promise.all(
      names.map(async (name) => {
        let uri = null;
        let state = null;
        try {
          const { stdout: info } = await execAsync(`lpstat -v ${JSON.stringify(name)}`);
          const m = info.match(/device for [^:]+:\s*(.+)$/m);
          if (m) uri = m[1].trim();
        } catch (_) {}
        try {
          const { stdout: s } = await execAsync(`lpstat -p ${JSON.stringify(name)}`);
          state = s.trim();
        } catch (_) {}
        return {
          name,
          driver: null,
          port: uri,
          share: null,
          default: name === defaultName,
          local: uri ? !/^(socket|ipp|http|lpd|smb):/.test(uri) : true,
          network: uri ? /^(socket|ipp|http|lpd|smb):/.test(uri) : false,
          status: state,
          connection: uri && /^(socket|ipp|http|lpd|smb):/.test(uri) ? 'network' : 'local'
        };
      })
    );
    return results;
  } catch (err) {
    logger.warn('CUPS lpstat failed:', err.message);
    return [];
  }
}

async function listPrinters() {
  if (PLATFORM === 'win32') return listPrintersWindows();
  return listPrintersCups();
}

function parseNetworkTarget(portOrUri) {
  if (!portOrUri) return null;
  const socketMatch = portOrUri.match(/^socket:\/\/([^:/]+):?(\d+)?/i);
  if (socketMatch) {
    return { host: socketMatch[1], port: parseInt(socketMatch[2] || '9100', 10) };
  }
  const ipMatch = portOrUri.match(/^(\d{1,3}\.){3}\d{1,3}(:\d+)?$/);
  if (ipMatch) {
    const [host, port] = portOrUri.split(':');
    return { host, port: parseInt(port || '9100', 10) };
  }
  return null;
}

function sendRawTcp(host, port, buffer) {
  return new Promise((resolve, reject) => {
    const socket = new net.Socket();
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error(`TCP timeout to ${host}:${port}`));
    }, 15000);

    socket.connect(port, host, () => {
      socket.write(buffer, () => socket.end());
    });
    socket.on('close', () => {
      clearTimeout(timer);
      resolve({ transport: 'tcp', bytes: buffer.length });
    });
    socket.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

async function sendRawWindows(printerName, buffer) {
  const tmp = await ensureTempDir();
  const filePath = path.join(tmp, `raw-${randomUUID()}.bin`);
  await fs.writeFile(filePath, buffer);
  const safeName = printerName.replace(/"/g, '');
  const safePath = filePath.replace(/'/g, "''");

  const ps = `
    $ErrorActionPreference = 'Stop';
    Add-Type -AssemblyName System.Drawing;
    $bytes = [System.IO.File]::ReadAllBytes('${safePath}');
    $printer = "${safeName}";
    $type = Add-Type -Name RawPrinter -Namespace Native -PassThru -MemberDefinition @'
      [DllImport("winspool.Drv", EntryPoint="OpenPrinterA", SetLastError=true, CharSet=CharSet.Ansi, ExactSpelling=true)]
      public static extern bool OpenPrinter(string src, out IntPtr hPrinter, IntPtr pd);
      [DllImport("winspool.Drv", EntryPoint="ClosePrinter", SetLastError=true)]
      public static extern bool ClosePrinter(IntPtr hPrinter);
      [DllImport("winspool.Drv", EntryPoint="StartDocPrinterA", SetLastError=true, CharSet=CharSet.Ansi)]
      public static extern bool StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOA di);
      [DllImport("winspool.Drv", EntryPoint="EndDocPrinter", SetLastError=true)]
      public static extern bool EndDocPrinter(IntPtr hPrinter);
      [DllImport("winspool.Drv", EntryPoint="StartPagePrinter", SetLastError=true)]
      public static extern bool StartPagePrinter(IntPtr hPrinter);
      [DllImport("winspool.Drv", EntryPoint="EndPagePrinter", SetLastError=true)]
      public static extern bool EndPagePrinter(IntPtr hPrinter);
      [DllImport("winspool.Drv", EntryPoint="WritePrinter", SetLastError=true)]
      public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, Int32 dwCount, out Int32 dwWritten);
      [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
      public class DOCINFOA { [MarshalAs(UnmanagedType.LPStr)] public string pDocName; [MarshalAs(UnmanagedType.LPStr)] public string pOutputFile; [MarshalAs(UnmanagedType.LPStr)] public string pDataType; }
'@;
    $h = [IntPtr]::Zero;
    if(-not [Native.RawPrinter]::OpenPrinter($printer, [ref]$h, [IntPtr]::Zero)){ throw "OpenPrinter failed" };
    try {
      $di = New-Object Native.RawPrinter+DOCINFOA;
      $di.pDocName = "LocalAgent RAW";
      $di.pDataType = "RAW";
      if(-not [Native.RawPrinter]::StartDocPrinter($h, 1, $di)){ throw "StartDocPrinter failed" };
      [Native.RawPrinter]::StartPagePrinter($h) | Out-Null;
      $pin = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length);
      try {
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $pin, $bytes.Length);
        $written = 0;
        if(-not [Native.RawPrinter]::WritePrinter($h, $pin, $bytes.Length, [ref]$written)){ throw "WritePrinter failed" };
      } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pin);
      };
      [Native.RawPrinter]::EndPagePrinter($h) | Out-Null;
      [Native.RawPrinter]::EndDocPrinter($h) | Out-Null;
    } finally {
      [Native.RawPrinter]::ClosePrinter($h) | Out-Null;
    };
    Write-Output "OK:$($bytes.Length)";
  `.replace(/\r?\n/g, ' ');

  try {
    const { stdout } = await execAsync(`powershell -NoProfile -Command "${ps.replace(/"/g, '\\"')}"`, {
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024
    });
    const m = stdout.match(/OK:(\d+)/);
    return { transport: 'winspool', bytes: m ? parseInt(m[1], 10) : buffer.length };
  } finally {
    fs.unlink(filePath).catch(() => {});
  }
}

async function sendRawCups(printerName, buffer, options = {}) {
  const tmp = await ensureTempDir();
  const filePath = path.join(tmp, `raw-${randomUUID()}.bin`);
  await fs.writeFile(filePath, buffer);
  try {
    const rawFlag = options.raw === false ? '' : '-o raw';
    const cmd = `lp -d ${JSON.stringify(printerName)} ${rawFlag} ${JSON.stringify(filePath)}`;
    const { stdout } = await execAsync(cmd, { maxBuffer: 4 * 1024 * 1024 });
    return { transport: 'cups', bytes: buffer.length, jobId: stdout.trim() };
  } finally {
    fs.unlink(filePath).catch(() => {});
  }
}

async function printRaw(printerName, data, options = {}) {
  if (!printerName) throw new Error('printerName is required');
  const buffer = normalizeToBuffer(data, options.encoding);

  const printers = await listPrinters();
  const printer = printers.find((p) => p.name === printerName);

  if (printer) {
    const target = parseNetworkTarget(printer.port);
    if (target && options.transport !== 'spooler') {
      return sendRawTcp(target.host, target.port, buffer);
    }
  } else if (options.transport === 'tcp' && options.host) {
    return sendRawTcp(options.host, options.port || 9100, buffer);
  }

  if (PLATFORM === 'win32') return sendRawWindows(printerName, buffer);
  return sendRawCups(printerName, buffer, options);
}

function normalizeToBuffer(data, encoding = 'utf8') {
  if (Buffer.isBuffer(data)) return data;
  if (data && typeof data === 'object' && data.type === 'Buffer' && Array.isArray(data.data)) {
    return Buffer.from(data.data);
  }
  if (typeof data === 'string') {
    if (encoding === 'base64') return Buffer.from(data, 'base64');
    if (encoding === 'hex') return Buffer.from(data, 'hex');
    return Buffer.from(data, 'utf8');
  }
  throw new Error('Unsupported data type for printRaw');
}

async function printImage(printerName, imageInput, options = {}) {
  if (!printerName) throw new Error('printerName is required');
  const tmp = await ensureTempDir();
  const buffer = await imageInputToBuffer(imageInput);

  const format = (options.format || 'auto').toLowerCase();

  if (format === 'escpos' || format === 'zpl') {
    const sharp = require('sharp');
    const width = options.widthDots || (format === 'zpl' ? 576 : 384);
    const raster = await sharp(buffer)
      .resize({ width, withoutEnlargement: true })
      .greyscale()
      .threshold(options.threshold || 128)
      .raw()
      .toBuffer({ resolveWithObject: true });

    if (format === 'escpos') {
      const escpos = buildEscPosRaster(raster.data, raster.info.width, raster.info.height);
      return printRaw(printerName, escpos, { encoding: 'buffer' });
    }
    const zpl = buildZplGraphic(raster.data, raster.info.width, raster.info.height, options);
    return printRaw(printerName, Buffer.from(zpl, 'binary'));
  }

  const outPath = path.join(tmp, `img-${randomUUID()}.png`);
  const sharp = require('sharp');
  await sharp(buffer).png().toFile(outPath);
  try {
    if (PLATFORM === 'win32') {
      const pdfPrinter = require('pdf-to-printer');
      await pdfPrinter.print(outPath, { printer: printerName, ...(options.printerOptions || {}) });
    } else {
      const unixPrint = require('unix-print');
      await unixPrint.print(outPath, printerName, options.cupsOptions || []);
    }
    return { transport: 'spooler', bytes: buffer.length };
  } finally {
    fs.unlink(outPath).catch(() => {});
  }
}

async function imageInputToBuffer(input) {
  if (Buffer.isBuffer(input)) return input;
  if (typeof input === 'string') {
    const b64 = input.replace(/^data:image\/[a-zA-Z+]+;base64,/, '');
    if (/^[A-Za-z0-9+/=\s]+$/.test(b64) && b64.length > 32) {
      return Buffer.from(b64, 'base64');
    }
    return fs.readFile(input);
  }
  if (input && input.base64) return Buffer.from(input.base64, 'base64');
  if (input && input.path) return fs.readFile(input.path);
  throw new Error('Unsupported image input');
}

function buildEscPosRaster(pixels, width, height) {
  const widthBytes = Math.ceil(width / 8);
  const bmp = Buffer.alloc(widthBytes * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const pixel = pixels[y * width + x];
      if (pixel === 0) {
        const byteIndex = y * widthBytes + Math.floor(x / 8);
        bmp[byteIndex] |= 0x80 >> (x % 8);
      }
    }
  }
  const header = Buffer.from([
    0x1d, 0x76, 0x30, 0x00,
    widthBytes & 0xff,
    (widthBytes >> 8) & 0xff,
    height & 0xff,
    (height >> 8) & 0xff
  ]);
  const init = Buffer.from([0x1b, 0x40]);
  const cut = Buffer.from([0x0a, 0x0a, 0x0a, 0x1d, 0x56, 0x00]);
  return Buffer.concat([init, header, bmp, cut]);
}

function buildZplGraphic(pixels, width, height, options = {}) {
  const widthBytes = Math.ceil(width / 8);
  const total = widthBytes * height;
  let hex = '';
  for (let y = 0; y < height; y++) {
    for (let bx = 0; bx < widthBytes; bx++) {
      let byte = 0;
      for (let bit = 0; bit < 8; bit++) {
        const x = bx * 8 + bit;
        if (x < width && pixels[y * width + x] === 0) {
          byte |= 0x80 >> bit;
        }
      }
      hex += byte.toString(16).padStart(2, '0').toUpperCase();
    }
  }
  const x = options.x || 0;
  const y = options.y || 0;
  return `^XA^FO${x},${y}^GFA,${total},${total},${widthBytes},${hex}^FS^XZ`;
}

module.exports = {
  listPrinters,
  printRaw,
  printImage,
  parseNetworkTarget
};
