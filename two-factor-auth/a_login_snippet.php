<?php
/**
 * ============================================================================
 * SNIPPET DE REFERENCIA — NO ES UN ARCHIVO EJECUTABLE COMPLETO
 * ============================================================================
 * Inserta este bloque en tu `a_login.php` real, DESPUÉS de validar
 * usuario+password (y de tener disponibles $codigo_usy y $login_usy),
 * y ANTES del redirect a `a_otpauth.php`.
 *
 * Reemplaza al bloque actual que redirige incondicionalmente al OTP.
 *
 * Requisitos previos en la sesión (los debes setear al inicio del login,
 * cuando cargas los datos del cliente):
 *
 *   $_SESSION["otpaut_cli"]   = 1 (pedir OTP) | 0 (no pedir)
 *   $_SESSION["totpfrq_cli"]  = minutos de gracia (ej. 360 = 6h)
 *                               0 o vacío → siempre pedir en cada logueo
 */

include_once("a_otp_device.php");

$decision = otp_dev_should_require($login_usy);

if ($decision['require_otp']) {

    // ---- Redirigir al OTP (flujo actual) ----
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
    // Aquí va la MISMA lógica que hoy corre en el case 2 de a_otpauth.php,
    // más la renovación de la cookie con el timestamp actual.

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

    // Renovar la cookie (extiende la ventana de gracia desde ahora)
    otp_dev_remember($login_usy);

    header("location: a_home.php?key=" . urlencode($strKey));
    exit;
}

/*
 * ============================================================================
 * Matriz de decisión (ver otp_dev_should_require)
 * ============================================================================
 *
 *  $_SESSION["otpaut_cli"]  $_SESSION["totpfrq_cli"]  cookie 'did' válida para $login_usy y ≤ N min   → OTP?
 *  -----------------------  ------------------------  ----------------------------------------------  -----
 *  0                        —                         —                                               NO
 *  1                        0 o vacío                 —                                               SI
 *  1                        > 0                       cookie ausente / firma inválida                 SI
 *  1                        > 0                       cookie de OTRO usuario                          SI
 *  1                        > 0                       cookie de este usuario, > totpfrq_cli minutos   SI
 *  1                        > 0                       cookie de este usuario, ≤ totpfrq_cli minutos   NO
 *
 * ============================================================================
 * Gestión adicional
 * ============================================================================
 *
 *   Logout / cambio de password / cualquier revocación
 *   → otp_dev_forget();     // borra la cookie del equipo actual
 *
 *   Puedes seguir renovando la cookie también dentro del propio a_otpauth.php
 *   (ya se hace tras un OTP válido en el case 1).
 */
