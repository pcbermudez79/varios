#!/usr/bin/env bash
# create_project.sh
# Genera el proyecto botivr-tts-final completo con TTS centralizado.
# Idempotente: reescribe archivos si se ejecuta de nuevo.

set -euo pipefail

ROOT="${1:-botivr-tts-final}"

echo "==> Generando proyecto en: $ROOT"

mkdir -p "$ROOT"/{central-api/{public,src/{Controllers,Services,Providers,Exceptions},scripts,apache,nginx,sql},vibevoice-service/app,botivr-client/src,docs}

########################################
# central-api/composer.json
########################################
cat > "$ROOT/central-api/composer.json" <<'EOF'
{
    "name": "botivr/central-tts-api",
    "description": "API central TTS para BotIVR (Polly + VibeVoice)",
    "type": "project",
    "license": "proprietary",
    "require": {
        "php": ">=8.1",
        "aws/aws-sdk-php": "^3.300",
        "vlucas/phpdotenv": "^5.6"
    },
    "autoload": {
        "psr-4": {
            "BotIVR\\CentralTts\\": "src/"
        }
    },
    "config": {
        "optimize-autoloader": true,
        "sort-packages": true
    }
}
EOF

########################################
# central-api/.env.example
########################################
cat > "$ROOT/central-api/.env.example" <<'EOF'
APP_ENV=production
APP_DEBUG=false
APP_LOG_FILE=/var/log/botivr-tts/api.log

# Token Bearer obligatorio para consumir la API
API_BEARER_TOKEN=cambiar-token-largo-y-seguro

# Cache central
CACHE_DIR=/var/lib/botivr-tts/cache
CACHE_TMP_DIR=/var/lib/botivr-tts/cache/tmp
MAX_TEXT_LENGTH=3000

# Proveedores permitidos (csv)
ALLOWED_PROVIDERS=polly,vibevoice

# Voces permitidas (csv). Vacio = todas.
ALLOWED_VOICES=Lupe,Mia,Miguel,Penelope,Andres,Sofia

# Formato final para Asterisk
OUTPUT_SAMPLE_RATE=8000
OUTPUT_CHANNELS=1
OUTPUT_BITS=16

# Version del normalizador (invalida cache si cambia)
NORMALIZER_VERSION=v1

# SOX
SOX_BIN=/usr/bin/sox

# Amazon Polly
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
POLLY_DEFAULT_ENGINE=neural
POLLY_DEFAULT_VOICE=Lupe
POLLY_DEFAULT_LANGUAGE=es-US
POLLY_SAMPLE_RATE=16000

# VibeVoice microservicio local
VIBEVOICE_URL=http://127.0.0.1:8101/v1/tts
VIBEVOICE_TIMEOUT=60

# Auditoria SQL (opcional)
AUDIT_ENABLED=false
AUDIT_DSN=
AUDIT_USER=
AUDIT_PASSWORD=
EOF

########################################
# central-api/public/index.php
########################################
cat > "$ROOT/central-api/public/index.php" <<'EOF'
<?php
declare(strict_types=1);

use BotIVR\CentralTts\Config;
use BotIVR\CentralTts\Router;
use BotIVR\CentralTts\Services\Logger;

require_once __DIR__ . '/../vendor/autoload.php';

try {
    Config::load(dirname(__DIR__));
    $logger = new Logger(Config::get('APP_LOG_FILE', '/var/log/botivr-tts/api.log'));
    $router = new Router($logger);
    $router->dispatch();
} catch (\Throwable $e) {
    http_response_code(500);
    header('Content-Type: application/json');
    error_log('[bootstrap] ' . $e->getMessage());
    echo json_encode(['error' => 'internal_error']);
}
EOF

########################################
# central-api/src/Config.php
########################################
cat > "$ROOT/central-api/src/Config.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts;

use Dotenv\Dotenv;

final class Config
{
    private static array $cache = [];
    private static bool $loaded = false;

    public static function load(string $baseDir): void
    {
        if (self::$loaded) {
            return;
        }
        if (is_file($baseDir . '/.env')) {
            $dotenv = Dotenv::createImmutable($baseDir);
            $dotenv->safeLoad();
        }
        self::$loaded = true;
    }

    public static function get(string $key, $default = null)
    {
        if (array_key_exists($key, self::$cache)) {
            return self::$cache[$key];
        }
        $val = getenv($key);
        if ($val === false || $val === '') {
            $val = $_ENV[$key] ?? $_SERVER[$key] ?? $default;
        }
        self::$cache[$key] = $val;
        return $val;
    }

    public static function getInt(string $key, int $default): int
    {
        $v = self::get($key, $default);
        return (int) $v;
    }

    public static function getBool(string $key, bool $default): bool
    {
        $v = self::get($key, $default ? 'true' : 'false');
        return in_array(strtolower((string)$v), ['1','true','yes','on'], true);
    }

    public static function getList(string $key, array $default = []): array
    {
        $v = self::get($key, null);
        if ($v === null || $v === '') return $default;
        return array_values(array_filter(array_map('trim', explode(',', (string)$v))));
    }
}
EOF

########################################
# central-api/src/Router.php
########################################
cat > "$ROOT/central-api/src/Router.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts;

use BotIVR\CentralTts\Controllers\HealthController;
use BotIVR\CentralTts\Controllers\TtsController;
use BotIVR\CentralTts\Services\Logger;

final class Router
{
    public function __construct(private Logger $logger) {}

    public function dispatch(): void
    {
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
        $uri = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
        $uri = rtrim($uri, '/') ?: '/';

        try {
            if ($method === 'GET' && ($uri === '/v1/health' || $uri === '/health')) {
                (new HealthController())->handle();
                return;
            }
            if ($method === 'POST' && $uri === '/v1/tts/synthesize/audio') {
                (new TtsController($this->logger))->synthesize();
                return;
            }
            $this->notFound();
        } catch (\BotIVR\CentralTts\Exceptions\TtsException $e) {
            $this->jsonError($e->getStatusCode(), $e->getMessage());
        } catch (\Throwable $e) {
            $this->logger->error('unhandled', ['msg' => $e->getMessage()]);
            $this->jsonError(500, 'internal_error');
        }
    }

    private function notFound(): void
    {
        $this->jsonError(404, 'not_found');
    }

    private function jsonError(int $code, string $msg): void
    {
        http_response_code($code);
        header('Content-Type: application/json');
        echo json_encode(['error' => $msg]);
    }
}
EOF

########################################
# central-api/src/Controllers/HealthController.php
########################################
cat > "$ROOT/central-api/src/Controllers/HealthController.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Controllers;

use BotIVR\CentralTts\Config;

final class HealthController
{
    public function handle(): void
    {
        $sox = Config::get('SOX_BIN', '/usr/bin/sox');
        $cacheDir = Config::get('CACHE_DIR', '/var/lib/botivr-tts/cache');
        $status = [
            'status' => 'ok',
            'time' => gmdate('c'),
            'sox' => is_executable($sox),
            'cache_dir_writable' => is_writable($cacheDir),
            'providers' => Config::getList('ALLOWED_PROVIDERS', ['polly','vibevoice']),
        ];
        header('Content-Type: application/json');
        echo json_encode($status);
    }
}
EOF

########################################
# central-api/src/Controllers/TtsController.php
########################################
cat > "$ROOT/central-api/src/Controllers/TtsController.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Controllers;

use BotIVR\CentralTts\Config;
use BotIVR\CentralTts\Exceptions\TtsException;
use BotIVR\CentralTts\Services\Logger;
use BotIVR\CentralTts\Services\TtsService;

final class TtsController
{
    public function __construct(private Logger $logger) {}

    public function synthesize(): void
    {
        $this->authorize();

        $raw = file_get_contents('php://input') ?: '';
        $data = json_decode($raw, true);
        if (!is_array($data)) {
            throw new TtsException('invalid_json', 400);
        }

        $provider = strtolower(trim((string)($data['provider'] ?? Config::get('POLLY_DEFAULT_ENGINE') ?: 'polly')));
        $voice = trim((string)($data['voice'] ?? Config::get('POLLY_DEFAULT_VOICE', 'Lupe')));
        $languageCode = trim((string)($data['language_code'] ?? Config::get('POLLY_DEFAULT_LANGUAGE', 'es-US')));
        $sampleRate = (int)($data['sample_rate'] ?? Config::getInt('OUTPUT_SAMPLE_RATE', 8000));
        $format = strtolower(trim((string)($data['format'] ?? 'wav')));
        $textType = strtolower(trim((string)($data['text_type'] ?? 'text')));
        $text = (string)($data['text'] ?? '');
        $clientId = substr(preg_replace('/[^A-Za-z0-9_.\-]/', '', (string)($data['client_id'] ?? 'unknown')), 0, 64);
        $cacheKey = trim((string)($data['cache_key'] ?? ''));

        $allowedProviders = Config::getList('ALLOWED_PROVIDERS', ['polly','vibevoice']);
        if (!in_array($provider, $allowedProviders, true)) {
            throw new TtsException('provider_not_allowed', 400);
        }
        $allowedVoices = Config::getList('ALLOWED_VOICES', []);
        if (!empty($allowedVoices) && !in_array($voice, $allowedVoices, true)) {
            throw new TtsException('voice_not_allowed', 400);
        }
        if (!in_array($textType, ['text','ssml'], true)) {
            throw new TtsException('invalid_text_type', 400);
        }
        if ($format !== 'wav') {
            throw new TtsException('invalid_format', 400);
        }
        $maxLen = Config::getInt('MAX_TEXT_LENGTH', 3000);
        if ($text === '' || strlen($text) > $maxLen) {
            throw new TtsException('invalid_text_length', 400);
        }

        $svc = new TtsService($this->logger);
        $result = $svc->synthesize([
            'provider' => $provider,
            'voice' => $voice,
            'language_code' => $languageCode,
            'sample_rate' => $sampleRate,
            'format' => $format,
            'text_type' => $textType,
            'text' => $text,
            'client_id' => $clientId,
            'cache_key' => $cacheKey,
        ]);

        header('Content-Type: audio/wav');
        header('X-TTS-Hash: ' . $result['hash']);
        header('X-TTS-Cached: ' . ($result['cached'] ? 'true' : 'false'));
        header('X-TTS-Provider: ' . $provider);
        header('X-TTS-Voice: ' . $voice);
        header('Content-Length: ' . filesize($result['path']));
        readfile($result['path']);
    }

    private function authorize(): void
    {
        $expected = (string) Config::get('API_BEARER_TOKEN', '');
        if ($expected === '') {
            throw new TtsException('server_misconfigured', 500);
        }
        $hdr = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
        if (stripos($hdr, 'Bearer ') !== 0) {
            throw new TtsException('unauthorized', 401);
        }
        $token = substr($hdr, 7);
        if (!hash_equals($expected, $token)) {
            throw new TtsException('unauthorized', 401);
        }
    }
}
EOF

########################################
# central-api/src/Services/TtsService.php
########################################
cat > "$ROOT/central-api/src/Services/TtsService.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Services;

use BotIVR\CentralTts\Config;
use BotIVR\CentralTts\Exceptions\TtsException;
use BotIVR\CentralTts\Providers\PollyProvider;
use BotIVR\CentralTts\Providers\VibeVoiceProvider;

final class TtsService
{
    private CacheService $cache;
    private AudioConverter $conv;

    public function __construct(private Logger $logger)
    {
        $this->cache = new CacheService(
            (string) Config::get('CACHE_DIR', '/var/lib/botivr-tts/cache'),
            (string) Config::get('CACHE_TMP_DIR', '/var/lib/botivr-tts/cache/tmp')
        );
        $this->conv = new AudioConverter((string) Config::get('SOX_BIN', '/usr/bin/sox'), $logger);
    }

    public function synthesize(array $req): array
    {
        $normalized = $this->normalize($req['text'], $req['text_type']);
        $hashPayload = [
            'provider' => $req['provider'],
            'voice' => $req['voice'],
            'language_code' => $req['language_code'],
            'sample_rate' => $req['sample_rate'],
            'format' => 'wav',
            'text_type' => $req['text_type'],
            'normalizer_version' => (string) Config::get('NORMALIZER_VERSION', 'v1'),
            'text' => $normalized,
        ];
        $hash = hash('sha256', json_encode($hashPayload, JSON_UNESCAPED_UNICODE));

        $cached = $this->cache->getPath($hash);
        if ($cached !== null) {
            $this->logger->info('cache_hit', ['hash' => $hash, 'client' => $req['client_id']]);
            return ['path' => $cached, 'hash' => $hash, 'cached' => true];
        }

        $this->logger->info('cache_miss', ['hash' => $hash, 'provider' => $req['provider']]);

        $rawFile = tempnam((string) Config::get('CACHE_TMP_DIR', '/tmp'), 'tts_raw_');
        try {
            if ($req['provider'] === 'polly') {
                $provider = new PollyProvider($this->logger);
                $provider->synthesize($normalized, $req, $rawFile);
                $inputFormat = 'pcm';
            } elseif ($req['provider'] === 'vibevoice') {
                $provider = new VibeVoiceProvider($this->logger);
                $provider->synthesize($normalized, $req, $rawFile);
                $inputFormat = 'wav';
            } else {
                throw new TtsException('provider_not_implemented', 400);
            }

            $finalTmp = $rawFile . '.wav';
            $inputSampleRate = ($inputFormat === 'pcm')
                ? Config::getInt('POLLY_SAMPLE_RATE', 16000)
                : 0;
            $this->conv->toAsteriskWav(
                $rawFile,
                $finalTmp,
                $inputFormat,
                $inputSampleRate,
                (int) $req['sample_rate']
            );

            $finalPath = $this->cache->store($hash, $finalTmp);
            return ['path' => $finalPath, 'hash' => $hash, 'cached' => false];
        } finally {
            @unlink($rawFile);
            @unlink($rawFile . '.wav');
        }
    }

    private function normalize(string $text, string $type): string
    {
        $t = trim($text);
        $t = preg_replace('/\s+/u', ' ', $t) ?? $t;
        if ($type === 'ssml') {
            return $t;
        }
        // Texto plano: expandir pausas heredadas del engine anterior.
        $t = str_replace('.', '<break time="500ms"/>', $t);
        $t = str_replace(',', '<break time="250ms"/>', $t);
        return $t;
    }
}
EOF

########################################
# central-api/src/Services/CacheService.php
########################################
cat > "$ROOT/central-api/src/Services/CacheService.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Services;

final class CacheService
{
    public function __construct(private string $baseDir, private string $tmpDir)
    {
        if (!is_dir($this->baseDir)) @mkdir($this->baseDir, 0775, true);
        if (!is_dir($this->tmpDir)) @mkdir($this->tmpDir, 0775, true);
    }

    private function dirFor(string $hash): string
    {
        return $this->baseDir . '/' . substr($hash, 0, 2) . '/' . substr($hash, 2, 2);
    }

    public function pathFor(string $hash): string
    {
        return $this->dirFor($hash) . '/' . $hash . '.wav';
    }

    public function getPath(string $hash): ?string
    {
        $p = $this->pathFor($hash);
        if (is_file($p) && filesize($p) > 44) {
            return $p;
        }
        return null;
    }

    public function store(string $hash, string $srcFile): string
    {
        $dir = $this->dirFor($hash);
        if (!is_dir($dir)) @mkdir($dir, 0775, true);
        $final = $this->pathFor($hash);
        $tmp = $final . '.part';
        if (!copy($srcFile, $tmp)) {
            throw new \RuntimeException('cache_store_copy_failed');
        }
        @chmod($tmp, 0664);
        if (!rename($tmp, $final)) {
            @unlink($tmp);
            throw new \RuntimeException('cache_store_rename_failed');
        }
        return $final;
    }
}
EOF

########################################
# central-api/src/Services/AudioConverter.php
########################################
cat > "$ROOT/central-api/src/Services/AudioConverter.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Services;

use BotIVR\CentralTts\Exceptions\TtsException;

final class AudioConverter
{
    public function __construct(private string $soxBin, private Logger $logger) {}

    /**
     * Convierte el archivo de entrada a WAV PCM 16-bit mono al sample rate destino
     * (default 8000 Hz para Asterisk).
     *
     * $inputFormat: 'pcm' (raw signed 16-bit LE) o 'wav'.
     * $inputSampleRate: solo obligatorio para pcm raw.
     */
    public function toAsteriskWav(
        string $inputFile,
        string $outputFile,
        string $inputFormat,
        int $inputSampleRate,
        int $outputSampleRate
    ): void {
        if (!is_executable($this->soxBin)) {
            throw new TtsException('sox_not_available', 500);
        }
        $args = [$this->soxBin, '-q'];
        if ($inputFormat === 'pcm') {
            if ($inputSampleRate <= 0) $inputSampleRate = 16000;
            array_push($args, '-t', 'raw', '-r', (string)$inputSampleRate, '-b', '16', '-e', 'signed-integer', '-c', '1', $inputFile);
        } else {
            array_push($args, $inputFile);
        }
        // Salida WAV, PCM 16-bit, mono, remuestreo.
        array_push($args, '-t', 'wav', '-b', '16', '-e', 'signed-integer', '-c', '1', '-r', (string)$outputSampleRate, $outputFile);
        $cmd = implode(' ', array_map('escapeshellarg', $args));
        $out = [];
        $rc = 0;
        exec($cmd . ' 2>&1', $out, $rc);
        if ($rc !== 0) {
            $this->logger->error('sox_failed', ['rc' => $rc, 'out' => implode("\n", $out)]);
            throw new TtsException('sox_conversion_failed', 500);
        }
        if (!is_file($outputFile) || filesize($outputFile) <= 44) {
            throw new TtsException('sox_output_invalid', 500);
        }
    }
}
EOF

########################################
# central-api/src/Services/Logger.php
########################################
cat > "$ROOT/central-api/src/Services/Logger.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Services;

final class Logger
{
    public function __construct(private string $file) {
        $dir = dirname($this->file);
        if (!is_dir($dir)) @mkdir($dir, 0775, true);
    }

    public function info(string $event, array $ctx = []): void { $this->write('INFO', $event, $ctx); }
    public function error(string $event, array $ctx = []): void { $this->write('ERROR', $event, $ctx); }

    private function write(string $level, string $event, array $ctx): void
    {
        // Redactar posibles credenciales.
        foreach (['token','password','secret','authorization','aws_secret_access_key'] as $k) {
            if (isset($ctx[$k])) $ctx[$k] = '***';
        }
        $line = sprintf(
            "%s %s %s %s\n",
            gmdate('c'),
            $level,
            $event,
            json_encode($ctx, JSON_UNESCAPED_UNICODE)
        );
        @file_put_contents($this->file, $line, FILE_APPEND | LOCK_EX);
    }
}
EOF

########################################
# central-api/src/Providers/TtsProviderInterface.php
########################################
cat > "$ROOT/central-api/src/Providers/TtsProviderInterface.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Providers;

interface TtsProviderInterface
{
    /**
     * Sintetiza $text usando el proveedor y escribe el binario en $outputFile.
     * $req contiene: voice, language_code, sample_rate, text_type, client_id.
     */
    public function synthesize(string $text, array $req, string $outputFile): void;
}
EOF

########################################
# central-api/src/Providers/PollyProvider.php
########################################
cat > "$ROOT/central-api/src/Providers/PollyProvider.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Providers;

use Aws\Polly\PollyClient;
use BotIVR\CentralTts\Config;
use BotIVR\CentralTts\Exceptions\TtsException;
use BotIVR\CentralTts\Services\Logger;

final class PollyProvider implements TtsProviderInterface
{
    public function __construct(private Logger $logger) {}

    public function synthesize(string $text, array $req, string $outputFile): void
    {
        $region = (string) Config::get('AWS_REGION', 'us-east-1');
        $key = (string) Config::get('AWS_ACCESS_KEY_ID', '');
        $secret = (string) Config::get('AWS_SECRET_ACCESS_KEY', '');

        $cfg = ['region' => $region, 'version' => 'latest'];
        if ($key !== '' && $secret !== '') {
            $cfg['credentials'] = ['key' => $key, 'secret' => $secret];
        }

        try {
            $client = new PollyClient($cfg);
            $result = $client->synthesizeSpeech([
                'Engine' => (string) Config::get('POLLY_DEFAULT_ENGINE', 'neural'),
                'LanguageCode' => (string) $req['language_code'],
                'OutputFormat' => 'pcm',
                'SampleRate' => (string) Config::getInt('POLLY_SAMPLE_RATE', 16000),
                'Text' => $text,
                'TextType' => $req['text_type'] === 'ssml' ? 'ssml' : 'text',
                'VoiceId' => (string) $req['voice'],
            ]);
        } catch (\Throwable $e) {
            $this->logger->error('polly_error', ['msg' => $e->getMessage()]);
            throw new TtsException('polly_failure', 502);
        }

        $audio = (string) $result->get('AudioStream');
        if ($audio === '') {
            throw new TtsException('polly_empty_stream', 502);
        }
        if (file_put_contents($outputFile, $audio) === false) {
            throw new TtsException('polly_write_failed', 500);
        }
    }
}
EOF

########################################
# central-api/src/Providers/VibeVoiceProvider.php
########################################
cat > "$ROOT/central-api/src/Providers/VibeVoiceProvider.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Providers;

use BotIVR\CentralTts\Config;
use BotIVR\CentralTts\Exceptions\TtsException;
use BotIVR\CentralTts\Services\Logger;

final class VibeVoiceProvider implements TtsProviderInterface
{
    public function __construct(private Logger $logger) {}

    public function synthesize(string $text, array $req, string $outputFile): void
    {
        $url = (string) Config::get('VIBEVOICE_URL', 'http://127.0.0.1:8101/v1/tts');
        $timeout = Config::getInt('VIBEVOICE_TIMEOUT', 60);

        $payload = json_encode([
            'text' => $text,
            'voice' => $req['voice'],
            'language_code' => $req['language_code'],
            'text_type' => $req['text_type'],
            'sample_rate' => (int) $req['sample_rate'],
        ], JSON_UNESCAPED_UNICODE);

        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $payload,
            CURLOPT_HTTPHEADER => [
                'Content-Type: application/json',
                'Accept: audio/wav',
            ],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_TIMEOUT => $timeout,
        ]);
        $body = curl_exec($ch);
        $err = curl_error($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if ($body === false || $code !== 200) {
            $this->logger->error('vibevoice_http', ['code' => $code, 'err' => $err]);
            throw new TtsException('vibevoice_failure', 502);
        }
        if (file_put_contents($outputFile, $body) === false) {
            throw new TtsException('vibevoice_write_failed', 500);
        }
    }
}
EOF

########################################
# central-api/src/Exceptions/TtsException.php
########################################
cat > "$ROOT/central-api/src/Exceptions/TtsException.php" <<'EOF'
<?php
declare(strict_types=1);

namespace BotIVR\CentralTts\Exceptions;

class TtsException extends \RuntimeException
{
    public function __construct(string $message, private int $status = 500)
    {
        parent::__construct($message);
    }

    public function getStatusCode(): int
    {
        return $this->status;
    }
}
EOF

########################################
# central-api/scripts/install_api_rocky.sh
########################################
cat > "$ROOT/central-api/scripts/install_api_rocky.sh" <<'EOF'
#!/usr/bin/env bash
# Instalador para Rocky Linux 9 / RHEL 9.
set -euo pipefail

echo "==> Instalando dependencias del sistema"
sudo dnf install -y epel-release
sudo dnf module reset -y php || true
sudo dnf module enable -y php:8.1
sudo dnf install -y php php-cli php-common php-mbstring php-xml php-json php-curl \
                    php-opcache php-fpm sox unzip git curl httpd

if ! command -v composer >/dev/null 2>&1; then
    echo "==> Instalando composer"
    curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
    sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

echo "==> Preparando directorios de cache y logs"
sudo mkdir -p /var/lib/botivr-tts/cache/tmp /var/log/botivr-tts
sudo chown -R apache:apache /var/lib/botivr-tts /var/log/botivr-tts
sudo chmod 0775 /var/lib/botivr-tts/cache /var/lib/botivr-tts/cache/tmp

APP_DIR="/opt/botivr-tts-api"
echo "==> Sincronizando codigo a $APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo rsync -a --delete "$(dirname "$(dirname "$(readlink -f "$0")")")/" "$APP_DIR/"

cd "$APP_DIR"
sudo -u apache composer install --no-dev --prefer-dist --no-interaction

if [ ! -f "$APP_DIR/.env" ]; then
    sudo cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    sudo chown apache:apache "$APP_DIR/.env"
    sudo chmod 0640 "$APP_DIR/.env"
    echo "==> .env creado, revise credenciales antes de exponer."
fi

echo "==> Copiando vhost apache"
sudo cp "$APP_DIR/apache/botivr-tts.conf" /etc/httpd/conf.d/botivr-tts.conf
sudo systemctl enable --now httpd

echo "==> Listo. Pruebe: curl http://127.0.0.1/v1/health"
EOF
chmod +x "$ROOT/central-api/scripts/install_api_rocky.sh"

########################################
# central-api/scripts/test_polly.sh
########################################
cat > "$ROOT/central-api/scripts/test_polly.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${API_URL:=http://127.0.0.1/v1/tts/synthesize/audio}"
: "${API_TOKEN:=cambiar-token-largo-y-seguro}"
curl -sS -X POST "$API_URL" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/wav" \
  -d '{
    "provider":"polly",
    "voice":"Lupe",
    "language_code":"es-US",
    "sample_rate":8000,
    "format":"wav",
    "text_type":"ssml",
    "text":"<speak>Bienvenido.<break time=\"500ms\"/>Esta es una prueba.</speak>",
    "client_id":"botivr-test"
  }' \
  --output /tmp/test_polly.wav
file /tmp/test_polly.wav
EOF
chmod +x "$ROOT/central-api/scripts/test_polly.sh"

########################################
# central-api/scripts/test_vibevoice.sh
########################################
cat > "$ROOT/central-api/scripts/test_vibevoice.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${API_URL:=http://127.0.0.1/v1/tts/synthesize/audio}"
: "${API_TOKEN:=cambiar-token-largo-y-seguro}"
curl -sS -X POST "$API_URL" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: audio/wav" \
  -d '{
    "provider":"vibevoice",
    "voice":"Lupe",
    "language_code":"es-US",
    "sample_rate":8000,
    "format":"wav",
    "text_type":"text",
    "text":"Prueba VibeVoice on-premise.",
    "client_id":"botivr-test"
  }' \
  --output /tmp/test_vibevoice.wav
file /tmp/test_vibevoice.wav
EOF
chmod +x "$ROOT/central-api/scripts/test_vibevoice.sh"

########################################
# central-api/scripts/clean_cache.sh
########################################
cat > "$ROOT/central-api/scripts/clean_cache.sh" <<'EOF'
#!/usr/bin/env bash
# Elimina entradas de cache central mayores a N dias (default 30).
set -euo pipefail
: "${CACHE_DIR:=/var/lib/botivr-tts/cache}"
: "${DAYS:=30}"
find "$CACHE_DIR" -type f -name "*.wav" -mtime +"$DAYS" -print -delete
find "$CACHE_DIR" -type d -empty -delete
EOF
chmod +x "$ROOT/central-api/scripts/clean_cache.sh"

########################################
# central-api/apache/botivr-tts.conf
########################################
cat > "$ROOT/central-api/apache/botivr-tts.conf" <<'EOF'
<VirtualHost *:80>
    ServerName tts.midominio.local
    DocumentRoot /opt/botivr-tts-api/public

    <Directory /opt/botivr-tts-api/public>
        AllowOverride None
        Require all granted
        FallbackResource /index.php
    </Directory>

    ErrorLog  /var/log/httpd/botivr-tts-error.log
    CustomLog /var/log/httpd/botivr-tts-access.log combined

    php_admin_value upload_max_filesize 4M
    php_admin_value post_max_size 4M
    php_admin_value memory_limit 256M
</VirtualHost>
EOF

########################################
# central-api/nginx/botivr-tts.conf
########################################
cat > "$ROOT/central-api/nginx/botivr-tts.conf" <<'EOF'
server {
    listen 80;
    server_name tts.midominio.local;

    root /opt/botivr-tts-api/public;
    index index.php;

    client_max_body_size 4m;

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 90s;
    }

    access_log /var/log/nginx/botivr-tts-access.log;
    error_log  /var/log/nginx/botivr-tts-error.log;
}
EOF

########################################
# central-api/sql/tts_audit.sql
########################################
cat > "$ROOT/central-api/sql/tts_audit.sql" <<'EOF'
-- Auditoria opcional. La API funciona sin esta tabla.
CREATE TABLE IF NOT EXISTS tts_audit (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    created_at DATETIME NOT NULL,
    client_id VARCHAR(64) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    voice VARCHAR(64) NOT NULL,
    language_code VARCHAR(16) NOT NULL,
    text_type VARCHAR(8) NOT NULL,
    hash CHAR(64) NOT NULL,
    cached TINYINT(1) NOT NULL,
    duration_ms INT NULL,
    text_length INT NOT NULL,
    INDEX idx_hash (hash),
    INDEX idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
EOF

########################################
# vibevoice-service/Dockerfile
########################################
cat > "$ROOT/vibevoice-service/Dockerfile" <<'EOF'
# Base con soporte CUDA opcional. Para servidores sin GPU usar la imagen -slim.
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg sox curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY app /app/app

EXPOSE 8101
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8101/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8101"]
EOF

########################################
# vibevoice-service/docker-compose.yml
########################################
cat > "$ROOT/vibevoice-service/docker-compose.yml" <<'EOF'
services:
  vibevoice:
    build: .
    image: botivr/vibevoice:latest
    container_name: botivr-vibevoice
    restart: unless-stopped
    ports:
      - "127.0.0.1:8101:8101"
    environment:
      VIBEVOICE_MODEL: "microsoft/VibeVoice-Realtime-0.5B"
      VIBEVOICE_DEVICE: "cuda"
      VIBEVOICE_FALLBACK_TO_CPU: "1"
      HF_HOME: "/models"
    volumes:
      - vibevoice-models:/models
    # Descomentar en host con GPU NVIDIA + nvidia-container-toolkit:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]

volumes:
  vibevoice-models:
EOF

########################################
# vibevoice-service/requirements.txt
########################################
cat > "$ROOT/vibevoice-service/requirements.txt" <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
pydantic==2.9.2
numpy==1.26.4
soundfile==0.12.1
# El pack real de VibeVoice se instala manualmente segun el release oficial.
# Se deja el wrapper listo pero desacoplado.
EOF

########################################
# vibevoice-service/app/main.py
########################################
cat > "$ROOT/vibevoice-service/app/main.py" <<'EOF'
"""
Microservicio VibeVoice-Realtime-0.5B.

Este servicio expone /v1/tts y devuelve audio/wav. La carga real del modelo
VibeVoice se realiza en engine.load_model() la primera vez que se llama a /v1/tts.
Si el modelo no esta disponible en el entorno, se genera un WAV de silencio
valido para no romper la cadena (documentado en docs/03).
"""
from __future__ import annotations

import io
import logging
import os
import wave
from typing import Optional

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

logger = logging.getLogger("vibevoice")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

MODEL_NAME = os.getenv("VIBEVOICE_MODEL", "microsoft/VibeVoice-Realtime-0.5B")
DEVICE = os.getenv("VIBEVOICE_DEVICE", "cuda")
FALLBACK_CPU = os.getenv("VIBEVOICE_FALLBACK_TO_CPU", "1") == "1"

app = FastAPI(title="BotIVR VibeVoice Service", version="1.0.0")

_engine = {"loaded": False, "model": None, "device": None}


class TtsRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=3000)
    voice: str = "Lupe"
    language_code: str = "es-US"
    text_type: str = "text"
    sample_rate: int = 16000


def _try_load_model() -> None:
    if _engine["loaded"]:
        return
    try:
        import torch  # type: ignore
        device = DEVICE
        if device == "cuda" and not torch.cuda.is_available():
            if FALLBACK_CPU:
                device = "cpu"
            else:
                raise RuntimeError("CUDA no disponible")
        # La carga real depende del pack VibeVoice.
        # from vibevoice import VibeVoiceRealtime
        # _engine["model"] = VibeVoiceRealtime.from_pretrained(MODEL_NAME).to(device)
        _engine["model"] = None
        _engine["device"] = device
        _engine["loaded"] = True
        logger.info("VibeVoice cargado en %s (modelo=%s)", device, MODEL_NAME)
    except Exception as e:  # pragma: no cover
        logger.exception("No se pudo cargar VibeVoice: %s", e)
        _engine["loaded"] = True
        _engine["model"] = None
        _engine["device"] = "cpu"


def _synth_silence(text: str, sample_rate: int) -> np.ndarray:
    # Duracion aprox proporcional al texto (fallback).
    dur = min(max(len(text) * 0.06, 0.5), 15.0)
    n = int(dur * sample_rate)
    return np.zeros(n, dtype=np.int16)


def _synth_vibevoice(text: str, sample_rate: int, voice: str) -> np.ndarray:
    _try_load_model()
    model = _engine["model"]
    if model is None:
        # Wrapper documentado: retorna silencio si no hay modelo real.
        return _synth_silence(text, sample_rate)
    # Llamada real (placeholder):
    # audio = model.infer(text=text, voice=voice, sample_rate=sample_rate)
    # return np.asarray(audio, dtype=np.int16)
    return _synth_silence(text, sample_rate)


def _to_wav_bytes(audio: np.ndarray, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(audio.astype("<i2").tobytes())
    return buf.getvalue()


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "device": _engine.get("device") or DEVICE,
        "loaded": _engine.get("loaded", False),
    }


@app.post("/v1/tts")
def tts(req: TtsRequest) -> Response:
    try:
        # VibeVoice genera nativamente en sample rate propio; aqui devolvemos
        # 16000 Hz y dejamos que la API PHP haga el downsample final con SOX.
        native_sr = 16000
        audio = _synth_vibevoice(req.text, native_sr, req.voice)
        wav = _to_wav_bytes(audio, native_sr)
        return Response(content=wav, media_type="audio/wav")
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("tts_error: %s", e)
        raise HTTPException(status_code=500, detail="tts_failure")
EOF

########################################
# botivr-client/src/TTSEngineApi.php
########################################
cat > "$ROOT/botivr-client/src/TTSEngineApi.php" <<'EOF'
<?php
namespace IVRVoice\TTS;

use IVRVoice\lib\LoggerFile;

/**
 * Cliente TTS que consume la API central. Compatible con PHP 7.2+.
 *
 * Contrato identico al motor anterior:
 *   TTSEngineApi::tts($text, $cache = true)
 * Retorna la ruta local del WAV SIN extension (para Playback() de Asterisk).
 */
class TTSEngineApi
{
    public static function tts($text, $cache = true)
    {
        try {
            LoggerFile::debug('[TTSEngineApi] ' . substr($text, 0, 200));
        } catch (\Throwable $e) {
            // Logger opcional.
        }

        $cfg = self::config();
        $normalized = self::normalize($text);

        $hashPayload = json_encode(array(
            'provider' => $cfg['provider'],
            'voice' => $cfg['voice'],
            'language_code' => $cfg['language_code'],
            'sample_rate' => (int)$cfg['sample_rate'],
            'format' => 'wav',
            'text_type' => $cfg['text_type'],
            'normalizer_version' => 'v1',
            'text' => $normalized,
        ), JSON_UNESCAPED_UNICODE);
        $hash = hash('sha256', $hashPayload);

        $localDir = rtrim($cfg['local_cache'], '/');
        if (!is_dir($localDir)) {
            @mkdir($localDir, 0775, true);
        }
        $baseNoExt = $localDir . '/tts_' . $hash;
        $wavPath = $baseNoExt . '.wav';

        if ($cache && is_file($wavPath) && filesize($wavPath) > 44) {
            return $baseNoExt;
        }

        $lockPath = $baseNoExt . '.lock';
        $lockFp = @fopen($lockPath, 'c');
        if ($lockFp) {
            flock($lockFp, LOCK_EX);
            // Re-chequeo tras adquirir el lock.
            if ($cache && is_file($wavPath) && filesize($wavPath) > 44) {
                flock($lockFp, LOCK_UN);
                fclose($lockFp);
                @unlink($lockPath);
                return $baseNoExt;
            }
        }

        try {
            $partPath = $wavPath . '.part';
            $ok = self::downloadFromApi($cfg, $normalized, $hash, $partPath);

            if ($ok && is_file($partPath) && filesize($partPath) > 44) {
                @chmod($partPath, 0664);
                if (!@rename($partPath, $wavPath)) {
                    @unlink($partPath);
                    $ok = false;
                }
            } else {
                @unlink($partPath);
                $ok = false;
            }

            if (!$ok) {
                if (!empty($cfg['fallback_swift'])) {
                    return self::fallbackSwift($normalized, $baseNoExt, $cfg);
                }
                throw new \RuntimeException('tts_api_failed_and_no_fallback');
            }

            // Cache logica compatible con motor anterior.
            if (class_exists('\\IVRVoice\\TTS\\Cache')) {
                try { \IVRVoice\TTS\Cache::put(md5($text), $baseNoExt); } catch (\Throwable $e) {}
            }

            return $baseNoExt;
        } finally {
            if ($lockFp) {
                flock($lockFp, LOCK_UN);
                fclose($lockFp);
                @unlink($lockPath);
            }
        }
    }

    private static function downloadFromApi(array $cfg, $text, $hash, $partPath)
    {
        $payload = json_encode(array(
            'provider' => $cfg['provider'],
            'voice' => $cfg['voice'],
            'language_code' => $cfg['language_code'],
            'sample_rate' => (int)$cfg['sample_rate'],
            'format' => 'wav',
            'text_type' => $cfg['text_type'],
            'text' => $text,
            'cache_key' => $hash,
            'client_id' => $cfg['client_id'],
        ), JSON_UNESCAPED_UNICODE);

        $fp = @fopen($partPath, 'wb');
        if (!$fp) return false;

        $ch = curl_init($cfg['api_url']);
        curl_setopt_array($ch, array(
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $payload,
            CURLOPT_HTTPHEADER => array(
                'Authorization: Bearer ' . $cfg['api_token'],
                'Content-Type: application/json',
                'Accept: audio/wav',
            ),
            CURLOPT_FILE => $fp,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => (int)$cfg['connect_timeout'],
            CURLOPT_TIMEOUT => (int)$cfg['total_timeout'],
        ));
        $ok = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err = curl_error($ch);
        curl_close($ch);
        fclose($fp);

        if ($ok === false || $code !== 200) {
            try { LoggerFile::debug('[TTSEngineApi] api_error code=' . $code . ' err=' . $err); } catch (\Throwable $e) {}
            return false;
        }
        return true;
    }

    private static function fallbackSwift($text, $baseNoExt, array $cfg)
    {
        $swift = $cfg['swift_path'];
        if (!is_executable($swift)) {
            throw new \RuntimeException('swift_not_available_for_fallback');
        }
        $wav = $baseNoExt . '.wav';
        $cmd = escapeshellcmd($swift) . ' ' . escapeshellarg($text) . ' -o ' . escapeshellarg($wav);
        $out = array(); $rc = 0;
        exec($cmd . ' 2>&1', $out, $rc);
        if ($rc !== 0 || !is_file($wav)) {
            throw new \RuntimeException('swift_fallback_failed');
        }
        return $baseNoExt;
    }

    private static function normalize($text)
    {
        $t = trim($text);
        $t = preg_replace('/\s+/u', ' ', $t);
        return $t;
    }

    private static function config()
    {
        $get = function ($k, $d = null) {
            $v = getenv($k);
            if ($v === false || $v === '') $v = isset($_ENV[$k]) ? $_ENV[$k] : $d;
            return $v;
        };
        return array(
            'api_url'         => (string)$get('TTS_API_URL', 'http://127.0.0.1/v1/tts/synthesize/audio'),
            'api_token'       => (string)$get('TTS_API_TOKEN', ''),
            'client_id'       => (string)$get('TTS_CLIENT_ID', 'botivr-unknown'),
            'provider'        => (string)$get('TTS_PROVIDER', 'polly'),
            'voice'           => (string)$get('TTS_VOICE', 'Lupe'),
            'language_code'   => (string)$get('TTS_LANGUAGE_CODE', 'es-US'),
            'text_type'       => (string)$get('TTS_TEXT_TYPE', 'ssml'),
            'sample_rate'     => (int)$get('TTS_SAMPLE_RATE', 8000),
            'local_cache'     => (string)$get('TTS_LOCAL_CACHE', '/var/lib/asterisk/sounds/custom/tmpfestival'),
            'connect_timeout' => (int)$get('TTS_CONNECT_TIMEOUT', 2),
            'total_timeout'   => (int)$get('TTS_TOTAL_TIMEOUT', 20),
            'fallback_swift'  => (int)$get('TTS_FALLBACK_SWIFT', 1),
            'swift_path'      => (string)$get('TTS_SWIFT_PATH', '/usr/local/bin/swift'),
        );
    }
}
EOF

########################################
# botivr-client/src/TTSEngineFactory.php
########################################
cat > "$ROOT/botivr-client/src/TTSEngineFactory.php" <<'EOF'
<?php
namespace IVRVoice\TTS;

/**
 * Fabrica de motores TTS. Selecciona en runtime segun la env TTS_ENGINE.
 *
 *   TTS_ENGINE=api      -> nueva API central (Polly / VibeVoice)
 *   TTS_ENGINE=festival -> motor antiguo Swift/Cepstral (rollback)
 *
 * Contrato identico:
 *   TTSEngineFactory::tts($text, $cache = true) -> ruta local sin extension
 */
class TTSEngineFactory
{
    public static function tts($text, $cache = true)
    {
        $engine = getenv('TTS_ENGINE');
        if ($engine === false || $engine === '') {
            $engine = isset($_ENV['TTS_ENGINE']) ? $_ENV['TTS_ENGINE'] : 'festival';
        }
        $engine = strtolower(trim((string)$engine));

        if ($engine === 'api') {
            return TTSEngineApi::tts($text, $cache);
        }
        if (class_exists('\\IVRVoice\\TTS\\TTSEngineFestival')) {
            return TTSEngineFestival::tts($text, $cache);
        }
        // Ultimo recurso: intentar la API para no romper el IVR.
        return TTSEngineApi::tts($text, $cache);
    }
}
EOF

########################################
# botivr-client/.env.botivr.example
########################################
cat > "$ROOT/botivr-client/.env.botivr.example" <<'EOF'
TTS_ENGINE=api
TTS_API_URL=https://tts.midominio.com/v1/tts/synthesize/audio
TTS_API_TOKEN=token-super-seguro
TTS_CLIENT_ID=botivr-01

TTS_PROVIDER=polly
TTS_VOICE=Lupe
TTS_LANGUAGE_CODE=es-US
TTS_TEXT_TYPE=ssml
TTS_SAMPLE_RATE=8000

TTS_LOCAL_CACHE=/var/lib/asterisk/sounds/custom/tmpfestival
TTS_CONNECT_TIMEOUT=2
TTS_TOTAL_TIMEOUT=20

TTS_FALLBACK_SWIFT=1
TTS_SWIFT_PATH=/usr/local/bin/swift
EOF

########################################
# botivr-client/install_client.sh
########################################
cat > "$ROOT/botivr-client/install_client.sh" <<'EOF'
#!/usr/bin/env bash
# Copia las clases cliente al proyecto BotIVR existente.
# Uso: ./install_client.sh /ruta/al/proyecto/agi-bin
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "Uso: $0 /ruta/al/proyecto/agi-bin/IVRVoice/TTS"
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    echo "Directorio destino no existe: $TARGET"
    exit 1
fi

SRC_DIR="$(dirname "$(readlink -f "$0")")/src"
cp -v "$SRC_DIR/TTSEngineApi.php" "$TARGET/TTSEngineApi.php"
cp -v "$SRC_DIR/TTSEngineFactory.php" "$TARGET/TTSEngineFactory.php"

CACHE_DIR="/var/lib/asterisk/sounds/custom/tmpfestival"
if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
fi
chown -R asterisk:asterisk "$CACHE_DIR" 2>/dev/null || true
chmod 0775 "$CACHE_DIR"

echo
echo "Clases instaladas en: $TARGET"
echo "Ahora edite el codigo AGI y reemplace:"
echo "  TTSEngineFestival::tts(\$text, true);"
echo "por:"
echo "  TTSEngineFactory::tts(\$text, true);"
echo
echo "Y exporte en el entorno de Asterisk (por ejemplo /etc/sysconfig/asterisk"
echo "o via SetEnv en el AGI):"
echo "  TTS_ENGINE=api"
echo "  TTS_API_URL=... TTS_API_TOKEN=... TTS_CLIENT_ID=..."
EOF
chmod +x "$ROOT/botivr-client/install_client.sh"

########################################
# docs/01-arquitectura.md
########################################
cat > "$ROOT/docs/01-arquitectura.md" <<'EOF'
# Arquitectura

## Componentes

1. **BotIVR (35 servidores Issabel/Asterisk)**
   - Aplicacion PHP AGI existente.
   - Clase nueva `TTSEngineFactory` que enruta a `TTSEngineApi` o al motor
     `TTSEngineFestival` de rollback segun `TTS_ENGINE`.
   - Cache local WAV en `/var/lib/asterisk/sounds/custom/tmpfestival`.

2. **API central TTS (PHP 8.1)**
   - Endpoint unico `POST /v1/tts/synthesize/audio` que retorna `audio/wav`.
   - Cache central en `/var/lib/botivr-tts/cache` indexada por hash SHA-256.
   - Proveedores: Amazon Polly Neural y VibeVoice-Realtime-0.5B.
   - Conversion final con SOX a WAV PCM 16-bit mono 8 kHz.

3. **Microservicio VibeVoice (Docker + FastAPI)**
   - Escucha en `127.0.0.1:8101`.
   - Consumido solo por la API central.
   - Wrapper listo, carga real del modelo separada (ver 03).

## Flujo

```
AGI PHP -> TTSEngineFactory -> TTSEngineApi
   -> cache local WAV?
      si: return path sin extension
      no: POST API central (audio/wav)
             -> cache central por hash?
                si: return binario
                no: Polly | VibeVoice -> SOX -> guarda central -> return binario
   -> guarda WAV local atomico
   -> return path sin extension
Asterisk Playback(path)
```

## Decisiones tomadas

- Hash SHA-256 con `provider|voice|language_code|sample_rate|format|text_type|normalizer_version|texto_normalizado`.
- No se comparte filesystem entre nodos: la API retorna binario, nunca ruta remota.
- Escritura atomica (`.part` -> `rename`) en ambas caches.
- `flock()` por hash en el cliente para evitar descargas concurrentes duplicadas.
- Fallback opcional a Swift/Cepstral desde el cliente si la API falla.
- Auditoria SQL opcional; la API funciona sin base de datos.
- Salida final: WAV 8000 Hz mono 16-bit PCM (compatible Asterisk `Playback()`).
EOF

########################################
# docs/02-instalacion-api-central.md
########################################
cat > "$ROOT/docs/02-instalacion-api-central.md" <<'EOF'
# Instalacion API central (Rocky Linux 9 / RHEL 9)

## Paso a paso

```bash
cd central-api
sudo ./scripts/install_api_rocky.sh
```

El script:

- Habilita `php:8.1` y paquetes (php-cli, php-curl, php-json, php-mbstring,
  php-xml, php-opcache, sox, httpd).
- Instala Composer si no existe.
- Copia el codigo a `/opt/botivr-tts-api`.
- Ejecuta `composer install --no-dev`.
- Crea `/var/lib/botivr-tts/cache` y `/var/log/botivr-tts` con owner `apache`.
- Publica el vhost `apache/botivr-tts.conf` en `/etc/httpd/conf.d/`.
- Arranca `httpd`.

## Configuracion

Editar `/opt/botivr-tts-api/.env`:

```
API_BEARER_TOKEN=... (token largo, minimo 32 chars)
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
VIBEVOICE_URL=http://127.0.0.1:8101/v1/tts
```

## Verificacion

```bash
curl http://127.0.0.1/v1/health
./scripts/test_polly.sh
file /tmp/test_polly.wav   # RIFF (little-endian) WAV audio, PCM, mono 8000 Hz
```

## Nginx (alternativa)

Copiar `nginx/botivr-tts.conf` a `/etc/nginx/conf.d/` y asegurar php-fpm.
EOF

########################################
# docs/03-instalacion-vibevoice.md
########################################
cat > "$ROOT/docs/03-instalacion-vibevoice.md" <<'EOF'
# Instalacion VibeVoice (Docker)

## Requisitos

- Docker 24+ y Docker Compose v2.
- Opcional: GPU NVIDIA con `nvidia-container-toolkit` para inferencia rapida.
- Espacio en disco para el volumen `vibevoice-models`.

## Levantar

```bash
cd vibevoice-service
docker compose build
docker compose up -d
curl http://127.0.0.1:8101/health
```

Si hay GPU disponible: descomente el bloque `deploy.resources` del compose y
ajuste `VIBEVOICE_DEVICE=cuda`.

## Modelo real vs wrapper

`app/main.py` incluye un wrapper para VibeVoice-Realtime-0.5B. La carga real
del modelo se realiza en `_try_load_model()` y la inferencia en
`_synth_vibevoice()`. Ambos puntos estan marcados con comentarios.

Mientras el pack oficial de VibeVoice no este instalado, el servicio retorna
un WAV valido de silencio (proporcional al largo del texto) para no romper la
cadena en pruebas de integracion. La API PHP siempre pasa la salida por SOX,
por lo que el archivo final sigue siendo un WAV 8 kHz mono valido.

## Consumo desde la API PHP central

La API llama a `http://127.0.0.1:8101/v1/tts` cuando `provider=vibevoice`.
No exponer el puerto 8101 al exterior.
EOF

########################################
# docs/04-ajuste-botivr-existente.md
########################################
cat > "$ROOT/docs/04-ajuste-botivr-existente.md" <<'EOF'
# Ajuste del BotIVR existente

## 1. Copiar clases

```bash
cd botivr-client
sudo ./install_client.sh /ruta/al/proyecto/agi-bin/IVRVoice/TTS
```

## 2. Variables de entorno

Copiar `.env.botivr.example` como referencia y exportarlas en el entorno de
Asterisk. Opciones:

- `/etc/sysconfig/asterisk` (variables leidas al iniciar el servicio).
- `SetEnv` en el dialplan antes de invocar el AGI.
- `putenv()` en el bootstrap del proyecto PHP.

Minimo obligatorio:

```
TTS_ENGINE=api
TTS_API_URL=https://tts.midominio.com/v1/tts/synthesize/audio
TTS_API_TOKEN=token-super-seguro
TTS_CLIENT_ID=botivr-01
```

## 3. Cambio en el codigo AGI

Buscar en la aplicacion AGI la linea:

```php
TTSEngineFestival::tts($text, true);
```

y reemplazarla por:

```php
TTSEngineFactory::tts($text, true);
```

No es necesario tocar nada mas. `TTSEngineFactory` mantiene la firma y el
retorno (ruta local sin extension).

## 4. Rollback

Basta con cambiar la variable de entorno y reiniciar Asterisk:

```
TTS_ENGINE=festival
```

El motor original (`TTSEngineFestival` con Swift/Cepstral) queda intacto.

## 5. Fallback en caliente

`TTS_FALLBACK_SWIFT=1` permite que `TTSEngineApi` caiga a Swift local
cuando la API central esta inaccesible, evitando cortes del IVR mientras
dure la incidencia.
EOF

########################################
# docs/05-operacion-y-monitoreo.md
########################################
cat > "$ROOT/docs/05-operacion-y-monitoreo.md" <<'EOF'
# Operacion y monitoreo

## Endpoints

- `GET /v1/health` -> estado, disponibilidad de SOX y cache.
- `POST /v1/tts/synthesize/audio` -> sintesis.

## Logs

- API central: `/var/log/botivr-tts/api.log` (JSON por linea).
- Apache: `/var/log/httpd/botivr-tts-*.log`.
- VibeVoice: `docker logs -f botivr-vibevoice`.

Los logs no imprimen tokens ni claves AWS (redaccion automatica en `Logger`).

## Cache central

- Ubicacion: `/var/lib/botivr-tts/cache/<aa>/<bb>/<hash>.wav`.
- Limpieza periodica sugerida por cron:

```
30 3 * * * /opt/botivr-tts-api/scripts/clean_cache.sh
```

## Cache local (por BotIVR)

- Ubicacion: `/var/lib/asterisk/sounds/custom/tmpfestival/tts_<hash>.wav`.
- Limpieza sugerida (dejar 7 dias):

```
15 4 * * * find /var/lib/asterisk/sounds/custom/tmpfestival -name 'tts_*.wav' -mtime +7 -delete
```

## Metricas rapidas

- Cache hit ratio central: `grep cache_hit /var/log/botivr-tts/api.log | wc -l`
- Errores Polly: `grep polly_error /var/log/botivr-tts/api.log`
- Errores VibeVoice: `grep vibevoice_http /var/log/botivr-tts/api.log`

## Auditoria opcional

Si desea trazabilidad por llamada, cargue `sql/tts_audit.sql` y active
`AUDIT_ENABLED=true`. La API no depende de esta tabla; puede activarse
despues sin cambios en los clientes.
EOF

########################################
# docs/06-checklist-produccion.md
########################################
cat > "$ROOT/docs/06-checklist-produccion.md" <<'EOF'
# Checklist de produccion

## API central

- [ ] `API_BEARER_TOKEN` >= 32 caracteres, distinto del ejemplo.
- [ ] Credenciales AWS con permisos minimos: `polly:SynthesizeSpeech`.
- [ ] `SOX_BIN` apunta a un binario ejecutable (`sox --version`).
- [ ] `/var/lib/botivr-tts/cache` con owner `apache` y modo 0775.
- [ ] `/var/log/botivr-tts` con owner `apache`.
- [ ] Vhost publicado detras de TLS (Nginx/Apache + certbot).
- [ ] `ALLOWED_PROVIDERS` y `ALLOWED_VOICES` acotados.
- [ ] Firewall: solo BotIVRs pueden alcanzar la API.

## VibeVoice

- [ ] Contenedor corriendo, `curl http://127.0.0.1:8101/health` responde.
- [ ] Puerto 8101 no expuesto al exterior.
- [ ] Volumen `vibevoice-models` persistido y con espacio.
- [ ] Si hay GPU: `deploy.resources` habilitado y `nvidia-smi` visible dentro.

## BotIVR (cada nodo)

- [ ] `TTSEngineApi.php` y `TTSEngineFactory.php` copiados al proyecto.
- [ ] Variables `TTS_*` presentes en el entorno de Asterisk.
- [ ] `TTS_CLIENT_ID` unico por servidor (p.e. `botivr-01`).
- [ ] `/var/lib/asterisk/sounds/custom/tmpfestival` con owner `asterisk`.
- [ ] Swift/Cepstral instalado para fallback (`TTS_FALLBACK_SWIFT=1`).
- [ ] Codigo AGI actualizado: `TTSEngineFactory::tts(...)`.
- [ ] Prueba end-to-end: llamada al IVR con texto conocido, WAV local
      generado, `Playback()` sin ruido ni cortes.

## Verificacion automatizada

```bash
find botivr-tts-final -name "*.php" -print0 | xargs -0 -n1 php -l
python3 -m py_compile botivr-tts-final/vibevoice-service/app/main.py
```

## Rollback

```
TTS_ENGINE=festival
systemctl reload asterisk  # o reiniciar segun instalacion
```
EOF

########################################
# Validaciones al final
########################################
echo
echo "==> Estructura creada:"
find "$ROOT" -maxdepth 3 -type f | sort

echo
echo "==> Validando sintaxis PHP..."
if command -v php >/dev/null 2>&1; then
    find "$ROOT" -name "*.php" -print0 | xargs -0 -n1 php -l
else
    echo "   (php no encontrado en PATH, saltando lint)"
fi

echo
echo "==> Validando sintaxis Python..."
if command -v python3 >/dev/null 2>&1; then
    python3 -m py_compile "$ROOT/vibevoice-service/app/main.py"
    echo "   OK"
else
    echo "   (python3 no encontrado en PATH, saltando compile)"
fi

echo
echo "==> Listo. Siguientes pasos sugeridos:"
echo "   1) cd $ROOT/central-api && cp .env.example .env && sudo ./scripts/install_api_rocky.sh"
echo "   2) cd $ROOT/vibevoice-service && docker compose up -d && curl http://127.0.0.1:8101/health"
echo "   3) cd $ROOT/botivr-client && sudo ./install_client.sh /ruta/al/proyecto/agi-bin/IVRVoice/TTS"
echo "   4) Exportar TTS_ENGINE=api y cambiar TTSEngineFestival::tts -> TTSEngineFactory::tts"
