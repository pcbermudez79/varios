<?php
/**
 * ============================================================================
 * SNIPPET DE REFERENCIA — NO ES UN ARCHIVO EJECUTABLE COMPLETO
 * ============================================================================
 * Inserta este bloque en tu `a_login.php` real, DESPUÉS de validar
 * usuario+password y de tener el `$codigo_usy` del usuario autenticado,
 * y ANTES del redirect a `a_otpauth.php`.
 *
 * Reemplaza al bloque actual que redirige incondicionalmente al OTP.
 */

include_once("a_otp_device.php");

// 1) Datos del cliente para conocer la política OTP configurada
$codcli = (int) valor_rcri("a_usersys", "codigo_usy = $codigo_usy", "codigo_cli");

$conf = arr_rcri1(
    "SELECT COALESCE(otpaut_cli, 0)  AS otpaut,
            COALESCE(otpfrq_cli, 1)  AS otpfrq,
            COALESCE(otpmin_cli, 60) AS otpmin
     FROM e_customer
     WHERE codigo_cli = $codcli",
    0
);
$otpaut = (int) ($conf[0]['otpaut'] ?? 0);
$otpfrq = (int) ($conf[0]['otpfrq'] ?? 1);   // 1=always, 2=grace
$otpmin = (int) ($conf[0]['otpmin'] ?? 60);  // minutos de gracia

// 2) Decisión
$decision = otp_dev_should_require($codigo_usy, $otpaut, $otpfrq, $otpmin);

// 3) Ejecutar
if ($decision['require_otp']) {

    // ---- Flujo actual: redirigir a a_otpauth.php ----
    $ccod = base64_encode(encrypt($codigo_usy));
    $key  = base64_encode(encrypt(json_encode([
        "ctime"      => time(),
        "session_id" => session_id(),
    ])));
    header("location: a_otpauth.php?cusy=" . urlencode($ccod)
                    . "&key="  . urlencode($key));
    exit;

} else {

    // ---- Dispositivo confiable dentro de la ventana de gracia ----
    // Aquí va la MISMA lógica que hoy corre después del OTP exitoso
    // (case 2 de a_otpauth.php): armar $rcParam, generar $strKey, cerrar
    // sesiones abiertas y redirigir a a_home.php.
    $arr_usr = arr_rcri1(
        "SELECT login_usy, passwd_usy FROM a_usersys WHERE codigo_usy = $codigo_usy",
        0
    );

    $rcParam = [
        "ccod_usuari" => $arr_usr[0]['login_usy'],
        "cpwd_usuari" => $arr_usr[0]['passwd_usy'],
        "ctime"       => time(),
        "session_id"  => session_id(),
    ];
    $strKey = base64_encode(encrypt(json_encode($rcParam)));

    ejecutar(1, "UPDATE e_acceso SET fecsal_acu = now()
                 WHERE cod_usuari = '" . $arr_usr[0]['login_usy'] . "'
                   AND fecacc_acu > current_date - 1
                   AND fecsal_acu IS NULL");

    $_SESSION['tcodigo_usy'] = $codigo_usy;

    header("location: a_home.php?key=" . urlencode($strKey));
    exit;
}

/*
 * ============================================================================
 * Matriz de decisión (ver otp_dev_should_require)
 * ============================================================================
 *
 *  otpaut_cli  otpfrq_cli   cookie 'did'    último OTP en device       → OTP?
 *  ----------  -----------  --------------  -------------------------  -----
 *  0 (off)     —            —               —                          NO
 *  ≥1          1 (always)   —               —                          SI
 *  ≥1          2 (grace)    ausente/mal     —                          SI
 *  ≥1          2 (grace)    válida          no hay registro            SI
 *  ≥1          2 (grace)    válida          > otpmin_cli minutos       SI
 *  ≥1          2 (grace)    válida          ≤ otpmin_cli minutos       NO
 *
 * ============================================================================
 * Gestión adicional
 * ============================================================================
 *
 *  - Cambio de password           → otp_dev_revoke_all($codigo_usy);
 *  - Botón "Cerrar sesión en otros
 *    dispositivos"                → otp_dev_revoke_all($codigo_usy);
 *  - Pantalla "Mis dispositivos"  → SELECT codigo_dev, useragent_dev, ip_dev,
 *                                          fecult_dev
 *                                   FROM   a_userdev
 *                                   WHERE  codigo_usy = ? AND codigo_est = 1;
 *                                   + botón que llame a otp_dev_revoke().
 */
