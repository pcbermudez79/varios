<?php
/**
 * 2FA — Trusted Device Helper (cookie-only, sin BD)
 *
 * Decide si hay que pedir OTP en el login actual leyendo:
 *   - $_SESSION["otpaut_cli"]    1 = pedir OTP, 0 = no pedir
 *   - $_SESSION["totpfrq_cli"]   minutos de vigencia de la ventana de gracia.
 *                                Si es 0 o vacío → siempre pedir OTP.
 *
 * La "identidad" del dispositivo vive en una cookie firmada `did`:
 *   payload = base64url(json_encode({ u: <login_usy>, t: <ts_unix> }))
 *   cookie  = payload . "." . hmac_sha256(payload, secret)
 *
 * De esa cookie podemos extraer el login del usuario y el timestamp de su
 * último logueo efectivo, y con eso decidir sin tocar BD.
 *
 * La cookie es por equipo + usuario: si otro usuario se autentica en el
 * mismo PC, la cookie se sobreescribe.
 */

if (!defined('OTP_DEVICE_COOKIE'))     define('OTP_DEVICE_COOKIE',    'did');
if (!defined('OTP_DEVICE_TTL_DAYS'))   define('OTP_DEVICE_TTL_DAYS',  90);
if (!defined('OTP_DEVICE_SECRET_ENV')) define('OTP_DEVICE_SECRET_ENV', 'OTP_DEVICE_SECRET');

/* -------------------------------------------------------------------------- */
/* Base                                                                        */
/* -------------------------------------------------------------------------- */

function otp_dev_secret() {
    $s = getenv(OTP_DEVICE_SECRET_ENV);
    if ($s) return $s;
    if (defined('ALONE_OTP_DEVICE_SECRET')) return ALONE_OTP_DEVICE_SECRET;
    // TODO: define ALONE_OTP_DEVICE_SECRET en aloneconfig.php con >= 32 bytes aleatorios
    return 'change-me-please-in-aloneconfig';
}

function otp_dev_b64u_encode($raw) {
    return rtrim(strtr(base64_encode($raw), '+/', '-_'), '=');
}

function otp_dev_b64u_decode($enc) {
    $pad = strlen($enc) % 4;
    if ($pad) $enc .= str_repeat('=', 4 - $pad);
    return base64_decode(strtr($enc, '-_', '+/'));
}

/* -------------------------------------------------------------------------- */
/* Firma y verificación de la cookie                                           */
/* -------------------------------------------------------------------------- */

/**
 * Construye el valor de cookie firmado a partir de login + timestamp.
 * @return string "<payload>.<sig>"
 */
function otp_dev_pack($login_usy, $ts) {
    $payload = otp_dev_b64u_encode(json_encode([
        'u' => (string) $login_usy,
        't' => (int)    $ts,
    ]));
    $sig = hash_hmac('sha256', $payload, otp_dev_secret());
    return $payload . '.' . $sig;
}

/**
 * Lee y valida la cookie firmada. Devuelve ['u' => login, 't' => ts] o null.
 */
function otp_dev_unpack($signed) {
    if (!$signed || strpos($signed, '.') === false) return null;

    list($payload, $sig) = explode('.', $signed, 2);
    $expected = hash_hmac('sha256', $payload, otp_dev_secret());
    if (!hash_equals($expected, $sig)) return null;

    $raw  = otp_dev_b64u_decode($payload);
    $data = json_decode($raw, true);

    if (!is_array($data) || empty($data['u']) || empty($data['t'])) return null;
    return ['u' => (string) $data['u'], 't' => (int) $data['t']];
}

function otp_dev_read_cookie() {
    return otp_dev_unpack($_COOKIE[OTP_DEVICE_COOKIE] ?? '');
}

function otp_dev_write_cookie($login_usy, $ts) {
    $val    = otp_dev_pack($login_usy, $ts);
    $secure = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    $exp    = time() + (OTP_DEVICE_TTL_DAYS * 86400);

    if (PHP_VERSION_ID >= 70300) {
        setcookie(OTP_DEVICE_COOKIE, $val, [
            'expires'  => $exp,
            'path'     => '/',
            'secure'   => $secure,
            'httponly' => true,
            'samesite' => 'Lax',
        ]);
    } else {
        setcookie(OTP_DEVICE_COOKIE, $val, $exp, '/; samesite=Lax', '', $secure, true);
    }
}

function otp_dev_delete_cookie() {
    $secure = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    if (PHP_VERSION_ID >= 70300) {
        setcookie(OTP_DEVICE_COOKIE, '', [
            'expires'  => time() - 3600,
            'path'     => '/',
            'secure'   => $secure,
            'httponly' => true,
            'samesite' => 'Lax',
        ]);
    } else {
        setcookie(OTP_DEVICE_COOKIE, '', time() - 3600, '/; samesite=Lax', '', $secure, true);
    }
    unset($_COOKIE[OTP_DEVICE_COOKIE]);
}

/* -------------------------------------------------------------------------- */
/* Decisión                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * ¿Hay que pedir OTP en el login actual?
 *
 * @param string $login_usy  login del usuario que se está autenticando
 * @return array ['require_otp' => bool, 'reason' => string]
 */
function otp_dev_should_require($login_usy) {
    // 1) OTP deshabilitado a nivel de cliente
    if ((int) ($_SESSION['otpaut_cli'] ?? 0) !== 1) {
        return ['require_otp' => false, 'reason' => 'otp_disabled'];
    }

    // 2) Sin ventana de gracia configurada → siempre pedir
    $mins = (int) ($_SESSION['totpfrq_cli'] ?? 0);
    if ($mins <= 0) {
        return ['require_otp' => true, 'reason' => 'policy_always'];
    }

    // 3) Leer la cookie
    $data = otp_dev_read_cookie();
    if ($data === null) {
        return ['require_otp' => true, 'reason' => 'no_device_cookie'];
    }

    // 4) La cookie debe pertenecer al MISMO login que se está autenticando
    if ($data['u'] !== (string) $login_usy) {
        return ['require_otp' => true, 'reason' => 'device_other_user'];
    }

    // 5) Verificar la ventana de gracia
    $elapsedMin = (time() - $data['t']) / 60;
    if ($elapsedMin > $mins) {
        return ['require_otp' => true, 'reason' => 'grace_expired'];
    }

    return ['require_otp' => false, 'reason' => 'grace_active'];
}

/**
 * Se llama DESPUÉS de una validación OTP exitosa (o al terminar un login
 * satisfactorio sin OTP, para renovar la cookie). Sobreescribe la cookie
 * con el login actual y el timestamp de ahora.
 */
function otp_dev_remember($login_usy) {
    otp_dev_write_cookie((string) $login_usy, time());
}

/** Borra la cookie del equipo actual (logout / revocación). */
function otp_dev_forget() {
    otp_dev_delete_cookie();
}
