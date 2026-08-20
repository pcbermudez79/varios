# Local Hardware Agent

Agente local liviano en Node.js — al estilo *QZ Tray* — para conectar aplicaciones
web con el sistema operativo del cliente: información de red, impresoras
instaladas, impresión **RAW** (ESC/POS, ZPL, EPL) y de imágenes, sin abrir el
cuadro de diálogo del navegador.

Se compone de dos piezas:

1. **Agente Node.js** que corre localmente y expone un servidor WebSocket
   (`ws://127.0.0.1:8080`) y HTTP (`http://127.0.0.1:8180`) con CORS y
   autenticación opcional por token.
2. **SDK JavaScript** para el frontend (`client-sdk/client-sdk.js`) que ofrece
   una API basada en `Promise`.

---

## 1. Estructura del proyecto

```
local-hardware-agent/
├── package.json
├── README.md
├── certs/                              # Certificados TLS locales (generados)
├── client-sdk/
│   └── client-sdk.js                   # SDK para el navegador
├── examples/
│   └── index.html                      # Demo web
├── scripts/
│   ├── generate-certs.js               # Genera certificados autofirmados
│   ├── install-windows.ps1             # Instala como servicio (NSSM) o autostart
│   ├── com.localhardware.agent.plist   # LaunchAgent de macOS
│   └── local-hardware-agent.service    # Unidad systemd Linux
└── src/
    ├── index.js                        # Bootstrap
    ├── config.js                       # Configuración por entorno
    ├── modules/
    │   ├── network.js                  # os + systeminformation
    │   └── printers.js                 # Spooler (winspool/CUPS) + TCP 9100
    ├── server/
    │   ├── router.js                   # Dispatcher de acciones
    │   ├── security.js                 # CORS + token
    │   ├── httpServer.js               # Express HTTP/HTTPS + /rpc
    │   └── wsServer.js                 # WebSocket/WSS
    └── utils/
        └── logger.js
```

---

## 2. Instalación y ejecución en desarrollo

```bash
cd local-hardware-agent
npm install
npm start
```

Salida esperada:

```
[..] [INFO] Starting Local Hardware Agent v1.0.0
[..] [INFO] Platform: linux (x64) — Node v18.x
[..] [INFO] Allowed origins: http://localhost, https://localhost, ...
[..] [WARN] API token NOT configured...
[..] [INFO] WS server listening on ws://127.0.0.1:8080
[..] [INFO] HTTP server listening on http://127.0.0.1:8180
```

### Variables de entorno

| Variable                 | Descripción                                                             | Default |
|--------------------------|-------------------------------------------------------------------------|---------|
| `AGENT_ALLOWED_ORIGINS`  | Orígenes CORS permitidos, separados por coma. Soporta `*.dominio.com`.  | `http://localhost,https://localhost,http://127.0.0.1,https://127.0.0.1` |
| `AGENT_API_TOKEN`        | Si se define, todas las peticiones deben incluirlo.                     | *(vacío)* |
| `AGENT_TLS`              | `true` para servir por WSS/HTTPS con los certs de `certs/`.             | `false` |
| `AGENT_LOG_LEVEL`        | `debug` \| `info` \| `warn` \| `error`.                                 | `info` |

### Generar certificados TLS locales

```bash
npm run gen-certs
# -> certs/agent.key + certs/agent.crt (SAN incluye localhost, 127.0.0.1, ::1)
```

Importa `agent.crt` en el trust store del SO para que los navegadores acepten
`wss://localhost:8443` sin advertencia.

---

## 3. API del agente (WS y HTTP comparten formato)

Todos los mensajes son JSON:

```json
{ "id": "req_1", "action": "printers.printRaw", "params": { ... } }
```

Respuesta:

```json
{ "id": "req_1", "ok": true, "action": "printers.printRaw", "data": { ... } }
```

### Acciones disponibles

| Action                | Params                                                            | Descripción |
|-----------------------|-------------------------------------------------------------------|-------------|
| `agent.ping`          | —                                                                 | Health check. |
| `agent.info`          | —                                                                 | Nombre, versión, SO. |
| `agent.auth`          | `{ token }`                                                       | Handshake (solo WS, si hay token). |
| `network.getInfo`     | —                                                                 | Hostname, IPs, MACs, interfaces, wifi. |
| `printers.list`       | —                                                                 | Impresoras locales / red. |
| `printers.printRaw`   | `{ printerName, data, encoding?, transport?, host?, port? }`      | RAW al spooler o directo a `host:9100`. |
| `printers.printImage` | `{ printerName, image, format?, widthDots?, threshold? }`         | Imagen (spooler, ESC/POS raster o ZPL `^GFA`). |

- `encoding`: `utf8` (default), `base64`, `hex`.
- `format`: `spooler` (default), `escpos`, `zpl`.
- `image`: string Base64 (con o sin prefijo `data:image/...`).

### Autenticación por HTTP

Envía el token en `X-Agent-Token: <token>` o `Authorization: Bearer <token>`.

---

## 4. SDK cliente

```html
<script src="/vendor/client-sdk.js"></script>
<script>
  const agent = HardwareAgent.create({
    host: '127.0.0.1',
    transport: 'ws',   // o 'http'
    secure: false,
    token: null
  });

  await agent.connect();
  const info = await agent.getNetworkInfo();
  const printers = await agent.getPrinters();
  await agent.printRaw(printers[0].name, '^XA^FO50,50^ADN,36,20^FDHola^FS^XZ');
</script>
```

También se puede usar como módulo:

```js
import HardwareAgent from './client-sdk.js';
const agent = HardwareAgent.create({ ... });
```

Demo completa en [`examples/index.html`](examples/index.html).

---

## 5. Compilar a ejecutable standalone

Se usa [`pkg`](https://github.com/vercel/pkg) (ya declarado en `devDependencies`).

```bash
npm install
npm run build:win     # dist/local-hardware-agent-win.exe
npm run build:mac     # dist/local-hardware-agent-macos
npm run build:linux   # dist/local-hardware-agent-linux
npm run build:all     # los tres
```

`pkg` empaqueta Node + código fuente + assets declarados en `package.json` →
`pkg.assets`. Los binarios nativos de `sharp` **no** son embebibles: en
producción se distribuye la carpeta `node_modules/sharp` junto al ejecutable, o
se instala como dependencia global en la máquina destino. Para builds sin
`sharp`, retira las llamadas a `printImage` con `format: 'escpos' | 'zpl'`.

Alternativas modernas:

- `npx @yao-pkg/pkg .` — fork mantenido de `pkg` con soporte Node 20/22.
- `deno compile` — si se decide portar el agente a Deno.
- `nexe` — genera binarios estáticos, útil en entornos sin acceso a `pkg`.

---

## 6. Ejecutar en segundo plano / al inicio del SO

### Windows

Opción A — Como servicio con [NSSM](https://nssm.cc):

```powershell
# Como administrador
copy dist\local-hardware-agent-win.exe "C:\Program Files\LocalHardwareAgent\"
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 `
  -ExePath "C:\Program Files\LocalHardwareAgent\local-hardware-agent-win.exe" `
  -AsService
```

Opción B — Autostart por usuario (sin admin), registra en `HKCU\...\Run`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 `
  -ExePath "C:\Users\Yo\LHA\local-hardware-agent-win.exe"
```

### macOS (LaunchAgent por usuario)

```bash
sudo cp dist/local-hardware-agent-macos /usr/local/bin/
sudo chmod +x /usr/local/bin/local-hardware-agent-macos
cp scripts/com.localhardware.agent.plist ~/Library/LaunchAgents/
launchctl load  ~/Library/LaunchAgents/com.localhardware.agent.plist
launchctl start com.localhardware.agent
```

Para uninstall: `launchctl unload ~/Library/LaunchAgents/com.localhardware.agent.plist`.

### Linux (systemd — user o system)

```bash
sudo cp dist/local-hardware-agent-linux /usr/local/bin/
sudo chmod +x /usr/local/bin/local-hardware-agent-linux

# Como servicio de usuario (no requiere root):
mkdir -p ~/.config/systemd/user
cp scripts/local-hardware-agent.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now local-hardware-agent

# Como servicio del sistema:
sudo cp scripts/local-hardware-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now local-hardware-agent
```

---

## 7. Notas de seguridad

- El agente **solo escucha en `127.0.0.1`**. Nunca lo expongas en `0.0.0.0`.
- Configura siempre `AGENT_ALLOWED_ORIGINS` con el dominio exacto de tu app.
- En producción, define `AGENT_API_TOKEN` y guárdalo en el frontend después
  del login (por ejemplo, en `sessionStorage`). Nunca hardcodees el token en JS
  público — solicítalo al backend tras autenticar al usuario.
- Habilita TLS (`AGENT_TLS=true`) si tu app web se sirve por HTTPS: los
  navegadores modernos bloquean `ws://` desde páginas `https://` (mixed content).
- Los datos RAW son binarios opacos: valida siempre `printerName` en tu
  backend antes de reenviarlo al agente si aceptas input del usuario.
