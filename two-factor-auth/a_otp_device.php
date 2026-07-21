<?php
/**
 * 2FA — Trusted Device Helper
 *
 * Gestiona el reconocimiento del dispositivo del usuario para decidir si
 * es necesario solicitar OTP según la política del cliente.
 *
 * Depende de:
 *   - arr_rcri1(), valor_rcri(), ejecutar()   (e_conexion.php / e_tools.php)
 *   - Tabla a_userdev y columnas e_customer.otpfrq_cli / otpmin_cli
 *     (ver sql/001_device_trust.sql)
 */

if (!defined('OTP_DEVICE_COOKIE'))       define('OTP_DEVICE_COOKIE',    'did');
if (!defined('OTP_DEVICE_TTL_DAYS'))     define('OTP_DEVICE_TTL_DAYS',  90);
if (!defined('OTP_DEVICE_SECRET_ENV'))   define('OTP_DEVICE_SECRET_ENV', 'OTP_DEVICE_SECRET');

/* -------------------------------------------------------------------------- */
/* Utilidades base                                                            */
/* -------------------------------------------------------------------------- */

function otp_dev_secret() {
    $s = getenv(OTP_DEVICE_SECRET_ENV);
    if ($s) return $s;
    if (defined('ALONE_OTP_DEVICE_SECRET')) return ALONE_OTP_DEVICE_SECRET;
    // TODO: define ALONE_OTP_DEVICE_SECRET en aloneconfig.php con un valor
    //       de al menos 32 bytes aleatorios antes de usar en producción.
    return 'change-me-please-in-aloneconfig';
}

function otp_dev_ip() {
    foreach (['HTTP_CF_CONNECTING_IP', 'HTTP_X_FORWARDED_FOR', 'HTTP_X_REAL_IP', 'REMOTE_ADDR'] as $k) {
        if (!empty($_SERVER[$k])) {
            $ip = trim(explode(',', $_SERVER[$k])[0]);
            if (filter_var($ip, FILTER_VALIDATE_IP)) return $ip;
        }
    }
    return '';
}

function otp_dev_ua() {
    return substr($_SERVER['HTTP_USER_AGENT'] ?? '', 0, 500);
}

/* -------------------------------------------------------------------------- */
/* Cookie firmada                                                             */
/* -------------------------------------------------------------------------- */

/** Firma un UUID crudo con HMAC-SHA256; devuelve "uuid.sig" */
function otp_dev_sign($uuid) {
    $sig = hash_hmac('sha256', $uuid, otp_dev_secret());
    return $uuid . '.' . $sig;
}

/** Verifica el valor firmado; devuelve el uuid crudo o '' si es inválido */
function otp_dev_verify($signed) {
    if (!$signed || strpos($signed, '.') === false) return '';
    list($uuid, $sig) = explode('.', $signed, 2);
    $expected = hash_hmac('sha256', $uuid, otp_dev_secret());
    return hash_equals($expected, $sig) ? $uuid : '';
}

function otp_dev_read_cookie() {
    return otp_dev_verify($_COOKIE[OTP_DEVICE_COOKIE] ?? '');
}

function otp_dev_set_cookie($uuid) {
    $signed = otp_dev_sign($uuid);
    $secure = !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off';
    $exp    = time() + (OTP_DEVICE_TTL_DAYS * 86400);

    if (PHP_VERSION_ID >= 70300) {
        setcookie(OTP_DEVICE_COOKIE, $signed, [
            'expires'  => $exp,
            'path'     => '/',
            'secure'   => $secure,
            'httponly' => true,
            'samesite' => 'Lax',
        ]);
    } else {
        setcookie(OTP_DEVICE_COOKIE, $signed, $exp, '/; samesite=Lax', '', $secure, true);
    }
}

function otp_dev_hash($uuid) {
    return hash('sha256', $uuid);
}

/* -------------------------------------------------------------------------- */
/* Lógica de decisión                                                         */
/* -------------------------------------------------------------------------- */

/**
 * Decide si hay que pedir OTP en el login actual.
 *
 * @param int|numeric $codigo_usy
 * @param int         $otpaut_cli  0=off, 1=email, 2=sms, 3=email+sms
 * @param int         $otpfrq_cli  1=always, 2=grace
 * @param int         $otpmin_cli  minutos de gracia (si otpfrq_cli=2)
 * @return array ['require_otp' => bool, 'reason' => string]
 */
function otp_dev_should_require($codigo_usy, $otpaut_cli, $otpfrq_cli, $otpmin_cli) {
    if ((int) $otpaut_cli === 0) {
        return ['require_otp' => false, 'reason' => 'otp_disabled'];
    }
    if ((int) $otpfrq_cli !== 2) {
        return ['require_otp' => true, 'reason' => 'policy_always'];
    }

    $uuid = otp_dev_read_cookie();
    if (!$uuid) {
        return ['require_otp' => true, 'reason' => 'no_device_cookie'];
    }

    $hash       = otp_dev_hash($uuid);
    $mins       = max(1, (int) $otpmin_cli);
    $codigo_usy = (int) $codigo_usy;

    $row = arr_rcri1(
        "SELECT codigo_dev,
                EXTRACT(EPOCH FROM (current_timestamp - fecult_dev))/60 AS mins
         FROM a_userdev
         WHERE codigo_usy = $codigo_usy
           AND hash_dev   = '" . addslashes($hash) . "'
           AND codigo_est = 1
           AND fecult_dev IS NOT NULL
         LIMIT 1",
        0
    );

    if (!is_array($row) || count($row) === 0) {
        return ['require_otp' => true, 'reason' => 'device_unknown'];
    }
    if ((float) $row[0]['mins'] > $mins) {
        return ['require_otp' => true, 'reason' => 'grace_expired'];
    }

    return ['require_otp' => false, 'reason' => 'grace_active'];
}

/**
 * Se llama DESPUÉS de una validación OTP exitosa. Registra o refresca el
 * dispositivo confiable y renueva la cookie firmada.
 */
function otp_dev_remember($codigo_usy) {
    $codigo_usy = (int) $codigo_usy;

    $uuid = otp_dev_read_cookie();
    if (!$uuid) {
        try {
            $uuid = bin2hex(random_bytes(16));
        } catch (Exception $e) {
            $uuid = bin2hex(openssl_random_pseudo_bytes(16));
        }
    }
    otp_dev_set_cookie($uuid); // renovar expiración siempre

    $hash   = otp_dev_hash($uuid);
    $ip     = otp_dev_ip();
    $ua     = otp_dev_ua();
    $ip_sql = $ip === '' ? "NULL" : "'" . addslashes($ip) . "'";
    $ua_sql = $ua === '' ? "NULL" : "'" . addslashes($ua) . "'";

    $exists = valor_rcri(
        "a_userdev",
        "codigo_usy = $codigo_usy AND hash_dev = '" . addslashes($hash) . "'",
        "codigo_dev"
    );

    if ($exists) {
        ejecutar(1,
            "UPDATE a_userdev
             SET fecult_dev    = current_timestamp,
                 ip_dev        = $ip_sql,
                 useragent_dev = $ua_sql,
                 codigo_est    = 1
             WHERE codigo_dev = $exists");
    } else {
        ejecutar(1,
            "INSERT INTO a_userdev
                (codigo_usy, hash_dev, useragent_dev, ip_dev, feccre_dev, fecult_dev, codigo_est)
             VALUES
                ($codigo_usy, '" . addslashes($hash) . "', $ua_sql, $ip_sql,
                 current_timestamp, current_timestamp, 1)");
    }
}

/** Revoca un dispositivo concreto (útil para pantalla "Mis dispositivos") */
function otp_dev_revoke($codigo_usy, $codigo_dev) {
    $codigo_usy = (int) $codigo_usy;
    $codigo_dev = (int) $codigo_dev;
    ejecutar(1, "UPDATE a_userdev SET codigo_est = 2
                 WHERE codigo_usy = $codigo_usy AND codigo_dev = $codigo_dev");
}

/** Revoca TODOS los dispositivos del usuario (cambio de password, sospecha, etc.) */
function otp_dev_revoke_all($codigo_usy) {
    $codigo_usy = (int) $codigo_usy;
    ejecutar(1, "UPDATE a_userdev SET codigo_est = 2 WHERE codigo_usy = $codigo_usy");
}
