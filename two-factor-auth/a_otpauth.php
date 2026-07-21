<?php
ini_set("display_errors", 1);
include_once("../conf/alone/aloneconfig.php");
aloneconfig();

include_once("../app/common/e_conexion.php");
include_once("../app/common/utilidades.php");
include_once("../app/common/e_tools.php");

// -----------------------------------------------------------------------------
// Configuración OTP
// -----------------------------------------------------------------------------
$OTP_RESEND_AFTER_SECONDS = 60;   // Tiempo mínimo entre reenvíos
$OTP_LIFETIME_MINUTES     = 5;    // Vigencia del token
$OTP_MAX_ATTEMPTS         = 5;    // Intentos máximos antes de bloquear

function get_client_ip() {
    foreach (['HTTP_CF_CONNECTING_IP', 'HTTP_X_FORWARDED_FOR', 'HTTP_X_REAL_IP', 'REMOTE_ADDR'] as $k) {
        if (!empty($_SERVER[$k])) {
            $ip = trim(explode(',', $_SERVER[$k])[0]);
            if (filter_var($ip, FILTER_VALIDATE_IP)) return $ip;
        }
    }
    return '';
}

/**
 * Genera un nuevo token OTP, lo inserta en a_usersys11 y lo despacha.
 * Cancela cualquier token pendiente previo del mismo usuario.
 *
 * @return array ['ok' => bool, 'msg' => string, 'sent_email' => bool, 'sent_sms' => bool]
 */
function otp_generate_and_send($codigo_usy, $codcli, $codusr, $type_otp, $email_msk_ref = null, $tel_msk_ref = null) {
    global $OTP_LIFETIME_MINUTES;

    $ip = get_client_ip();
    $ip_sql = $ip === '' ? "NULL" : "'" . addslashes($ip) . "'";

    // 1) Cancelar tokens vigentes previos (codigo_est = 5)
    $sqlCancel = "UPDATE a_usersys11
                  SET codigo_est = 5, feccan_res = current_timestamp
                  WHERE codigo_usy = $codigo_usy
                    AND toktyp_res = 2
                    AND codigo_est = 1";
    ejecutar(1, $sqlCancel);

    // 2) Generar y persistir nuevo token
    $token = str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT);
    $email_usr = valor_rcri("a_usersys", "codigo_usy = $codigo_usy", "email_usy");
    $email_sql = $email_usr ? "'" . addslashes($email_usr) . "'" : "NULL";

    $sqlIns = "INSERT INTO a_usersys11
                (codigo_usy, feccre_res, fecven_res, token_res, codigo_est, toktyp_res, email_res, inten_res, reqip_res)
               VALUES
                ($codigo_usy, current_timestamp,
                 current_timestamp + interval '$OTP_LIFETIME_MINUTES minutes',
                 '$token', 1, 2, $email_sql, 0, $ip_sql)";

    if (!ejecutar(1, $sqlIns)) {
        return ['ok' => false, 'msg' => 'Error creando el token, intenta nuevamente'];
    }

    $sent_email = false;
    $sent_sms   = false;
    $msg        = '';

    // 3) Enviar por correo
    if ($type_otp == 1 || $type_otp == 3) {
        include_once("a_mailer.php");
        $result = send_mail_otp($codigo_usy, 0);
        if ($result == "OK") {
            $sent_email = true;
            $msg .= "Se envió un código al buzón <strong>" . ($email_msk_ref ?: '') . "</strong>. ";
        } else {
            // Marcar como send_failed
            ejecutar(1, "UPDATE a_usersys11 SET codigo_est = 6
                         WHERE codigo_usy = $codigo_usy AND codigo_est = 1 AND toktyp_res = 2");
            $msg .= "Se presentó un error enviando el código al correo <strong>" . ($email_msk_ref ?: '') . "</strong>. ";
        }
    }

    // 4) Enviar por SMS
    if (($type_otp == 2 || $type_otp == 3) && $codcli > 0 && $codusr > 0) {
        $clicon = arr_rcri1("select * from e_customer11 where codigo_cli = " . $codcli, 0);
        app_set_conn($clicon);

        $arr_usr = arr_rcri1("select case
              when u.telcel_usr is not null and char_length(u.telcel_usr) = 10 and SUBSTRING(u.telcel_usr, 1, 1) = '3' then u.telcel_usr
              when u.telefo_usr is not null and char_length(u.telefo_usr) = 10 and SUBSTRING(u.telefo_usr, 1, 1) = '3' then u.telefo_usr
              when u.telfax_usr is not null and char_length(u.telfax_usr) = 10 and SUBSTRING(u.telfax_usr, 1, 1) = '3' then u.telfax_usr
              else '0' end as telefono
              from e_usuarios u where u.codigo_usr = $codusr", 0, 6);

        if (is_array($arr_usr) && count($arr_usr) > 0 && $arr_usr[0]["telefono"] !== '0') {
            include_once("a_smssend.php");
            $telcel = $arr_usr[0]["telefono"];
            send_sms_otp($codigo_usy, $telcel);
            $sent_sms = true;
            $msg .= "Se envió un código al celular <strong>" . ($tel_msk_ref ?: maskTel($telcel)) . "</strong>. ";
        }
    }

    return ['ok' => ($sent_email || $sent_sms), 'msg' => $msg];
}

// =============================================================================
// AJAX endpoints (POST)
// =============================================================================
$step = isset($_POST["step"]) ? (int) $_POST["step"] : 0;

if ($step > 0) {
    header('Content-Type: application/json; charset=utf-8');

    $ccod        = $_POST["ccod"] ?? '';
    $codigo_usy  = decrypt(base64_decode($ccod));
    $_SESSION['tcodigo_usy'] = 0;

    if (empty($codigo_usy)) {
        echo json_encode(["success" => false, "message" => "Sesión no válida"]);
        exit;
    }

    switch ($step) {

        // -------------------------------------------------------------
        // Case 1 — Verificar código OTP
        // -------------------------------------------------------------
        case 1:
            $token = strtoupper(preg_replace('/[^A-Z0-9]/', '', $_POST["code"] ?? ''));
            $ip    = get_client_ip();
            $ip_sql = $ip === '' ? "NULL" : "'" . addslashes($ip) . "'";

            $row = arr_rcri1(
                "SELECT codigo_res, token_res, inten_res
                 FROM a_usersys11
                 WHERE codigo_usy = $codigo_usy
                   AND toktyp_res = 2
                   AND codigo_est = 1
                   AND fecven_res >= current_timestamp
                 ORDER BY feccre_res DESC
                 LIMIT 1",
                0
            );

            if (!is_array($row) || count($row) == 0) {
                echo json_encode([
                    "success" => false,
                    "message" => "No hay un código vigente. Solicita un nuevo código.",
                    "expired" => true
                ]);
                break;
            }

            $codigo_res = $row[0]['codigo_res'];
            $lastCode   = $row[0]['token_res'];
            $intentos   = (int) $row[0]['inten_res'];

            if ($lastCode !== $token) {
                $intentos++;
                if ($intentos >= $OTP_MAX_ATTEMPTS) {
                    ejecutar(1, "UPDATE a_usersys11
                                 SET codigo_est = 4, inten_res = $intentos
                                 WHERE codigo_res = $codigo_res");
                    echo json_encode([
                        "success" => false,
                        "message" => "Has superado el número de intentos. Solicita un nuevo código.",
                        "blocked" => true
                    ]);
                } else {
                    ejecutar(1, "UPDATE a_usersys11
                                 SET inten_res = $intentos
                                 WHERE codigo_res = $codigo_res");
                    $rest = $OTP_MAX_ATTEMPTS - $intentos;
                    echo json_encode([
                        "success" => false,
                        "message" => "El código no es válido. Intentos restantes: $rest"
                    ]);
                }
                break;
            }

            // Válido → marcar verified
            ejecutar(1, "UPDATE a_usersys11
                         SET codigo_est = 2,
                             verifi_res = current_timestamp,
                             valip_res  = $ip_sql
                         WHERE codigo_res = $codigo_res");

            echo json_encode(["success" => true]);
            break;

        // -------------------------------------------------------------
        // Case 2 — Login final tras verificación
        // -------------------------------------------------------------
        case 2:
            $arr_usr = arr_rcri1(
                "SELECT login_usy, passwd_usy FROM a_usersys WHERE codigo_usy = $codigo_usy",
                0
            );

            if (is_array($arr_usr) && count($arr_usr) > 0) {
                $rcParam = [
                    "ccod_usuari" => $arr_usr[0]['login_usy'],
                    "cpwd_usuari" => $arr_usr[0]['passwd_usy'],
                    "ctime"       => time(),
                    "session_id"  => session_id()
                ];
                $strKey = base64_encode(encrypt(json_encode($rcParam)));

                ejecutar(1, "UPDATE e_acceso SET fecsal_acu = now()
                             WHERE cod_usuari = '" . $arr_usr[0]['login_usy'] . "'
                               AND fecacc_acu > current_date - 1
                               AND fecsal_acu IS NULL");

                $_SESSION['tcodigo_usy'] = $codigo_usy;
                echo json_encode(["success" => true, "key" => $strKey]);
            } else {
                echo json_encode(["success" => false, "message" => "Usuario no encontrado"]);
            }
            break;

        // -------------------------------------------------------------
        // Case 3 — Reenviar código OTP
        // -------------------------------------------------------------
        case 3:
            $usr = arr_rcri1(
                "SELECT email_usy, codigo_cli, codigo_usr
                 FROM a_usersys WHERE codigo_usy = $codigo_usy",
                0
            );
            if (!is_array($usr) || count($usr) == 0) {
                echo json_encode(["success" => false, "message" => "Usuario no encontrado"]);
                break;
            }

            $codcli   = (int) $usr[0]["codigo_cli"];
            $codusr   = (int) $usr[0]["codigo_usr"];
            $email    = $usr[0]["email_usy"];
            $type_otp = (int) valor_rcri("e_customer", "codigo_cli = $codcli", "otpaut_cli");

            if ($codcli <= 0 || $type_otp <= 0) {
                echo json_encode(["success" => false, "message" => "OTP no habilitado para este usuario"]);
                break;
            }

            // Rate-limit: exigir que el último token tenga al menos N segundos
            $lastCreated = valor_rcri(
                "a_usersys11",
                "codigo_usy = $codigo_usy AND toktyp_res = 2 ORDER BY feccre_res DESC LIMIT 1",
                "EXTRACT(EPOCH FROM (current_timestamp - feccre_res))::int"
            );

            if ($lastCreated !== null && $lastCreated !== '' && (int) $lastCreated < $OTP_RESEND_AFTER_SECONDS) {
                $wait = $OTP_RESEND_AFTER_SECONDS - (int) $lastCreated;
                echo json_encode([
                    "success" => false,
                    "message" => "Debes esperar $wait segundos para solicitar un nuevo código",
                    "wait"    => $wait
                ]);
                break;
            }

            $result = otp_generate_and_send(
                $codigo_usy, $codcli, $codusr, $type_otp,
                maskEmail($email), null
            );

            echo json_encode([
                "success" => $result['ok'],
                "message" => trim($result['msg']),
                "resend_after" => $OTP_RESEND_AFTER_SECONDS,
                "lifetime"     => $OTP_LIFETIME_MINUTES * 60
            ]);
            break;
    }

    exit;
}

// =============================================================================
// GET — pantalla inicial: genera primer código y renderiza modal
// =============================================================================
$ccod = $_GET["cusy"] ?? '';
$key  = $_GET["key"] ?? '';

$arrKey     = (array) json_decode(decrypt(base64_decode($_REQUEST["key"] ?? '')));
$codigo_usy = decrypt(base64_decode($ccod));

if (empty($codigo_usy)) {
    header("location: a_login.php");
    exit;
}

$timeexp = ($arrKey["ctime"] ?? 0) + (60 * 5); // 5 minutos
$timeact = time();

if (empty($arrKey) || ($arrKey["session_id"] ?? '') !== session_id()) {
    header("location: a_login.php?sessionexpire");
    exit;
}
if ($timeexp < $timeact) {
    header("location: a_login.php?timexpire");
    exit;
}

$arr_usr = arr_rcri1(
    "SELECT email_usy, nombre_usy, codigo_cli, codigo_usr
     FROM a_usersys WHERE codigo_usy = $codigo_usy"
);
$codcli   = (int) ($arr_usr[0]["codigo_cli"] ?? 0);
$msj_send = "";

if ($codcli > 0) {
    $email_msk = maskEmail($arr_usr[0]["email_usy"]);
    $codusr    = (int) $arr_usr[0]["codigo_usr"];
    $type_otp  = (int) valor_rcri("e_customer", "codigo_cli = $codcli", "otpaut_cli");

    if ($type_otp > 0) {
        $result = otp_generate_and_send(
            $codigo_usy, $codcli, $codusr, $type_otp, $email_msk, null
        );
        $msj_send = $result['msg'];
    }
}
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <title>Alone | Login</title>

    <link href="../app/bootstrap/css/bootstrap.min.css" rel="stylesheet">
    <link href="../app/bootstrap_others/css/bootstrap_fix.css" rel="stylesheet">
    <link href="../app/bootstrap/font-awesome/css/font-awesome.css" rel="stylesheet">

    <link href="../app/bootstrap/css/animate.css" rel="stylesheet">
    <link href="../app/bootstrap/css/style.css" rel="stylesheet">

    <link href="../app/bootstrap/css/plugins/sweetalert/sweetalert.css" rel="stylesheet">

    <link href="css/alone_login.css?v=1.1" rel="stylesheet">
    <link href="css/alone_login_01.css?v=1.1" rel="stylesheet">
    <link href="css/alone_otp.css?v=1.0" rel="stylesheet">

    <link href="css/plugins/jQueryUI/jquery-ui-1.10.4.custom.min.css" rel="stylesheet">
    <script src="js/jquery-3.1.1.min.js"></script>
    <script src="js/popper.min.js"></script>
    <script src="js/bootstrap.js"></script>
    <script src="js/plugins/metisMenu/jquery.metisMenu.js"></script>
    <script src="js/plugins/slimscroll/jquery.slimscroll.min.js"></script>
    <script src="js/inspinia.js"></script>
    <script src="js/plugins/pace/pace.min.js"></script>
    <script src="js/plugins/jquery-ui/jquery-ui.min.js"></script>
    <script src="js/bootstrap.min.js"></script>
    <script src="../app/js/ext/jquery.blockUI.js"></script>
    <script src="js/plugins/sweetalert/sweetalert.min.js"></script>
</head>
<body>
    <div class="modal otp-modal" id="userDataModal" tabindex="-1" aria-labelledby="userDataModalLabel"
         data-backdrop="static" data-keyboard="false" role="dialog" aria-hidden="true">
        <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content otp-card">
                <div class="modal-header otp-header">
                    <div class="otp-icon"><i class="fa fa-shield"></i></div>
                    <h2 class="modal-title" id="passwordModalLabel">Verificación de Acceso</h2>
                    <p class="otp-subtitle">Ingresa el código de 6 dígitos que enviamos para continuar</p>
                </div>

                <div class="modal-body">
                    <form id="changePasswordForm" autocomplete="off">
                        <input type="hidden" id="ccod" value="<?php print htmlspecialchars($ccod, ENT_QUOTES); ?>">
                        <input type="hidden" id="ckey" value="<?php print htmlspecialchars($key, ENT_QUOTES); ?>">

                        <div class="info-label alert alert-info" id="infoLabel">
                            <?php print $msj_send; ?>
                        </div>

                        <div class="code-container" id="codeContainer">
                            <input type="text" maxlength="1" class="code-input" id="code1" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 1">
                            <input type="text" maxlength="1" class="code-input" id="code2" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 2">
                            <input type="text" maxlength="1" class="code-input" id="code3" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 3">
                            <input type="text" maxlength="1" class="code-input" id="code4" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 4">
                            <input type="text" maxlength="1" class="code-input" id="code5" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 5">
                            <input type="text" maxlength="1" class="code-input" id="code6" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" aria-label="Dígito 6">
                        </div>

                        <div class="otp-error" id="otpError" role="alert"></div>

                        <div class="otp-actions">
                            <button type="button" class="btn btn-primary btn-lg btn-block" id="verifyOTPCodeBtn" disabled>
                                <span class="btn-label">Verificar Código</span>
                                <span class="btn-spinner" aria-hidden="true"></span>
                            </button>
                        </div>

                        <div class="otp-resend">
                            <span id="resendHint" class="resend-hint">
                                ¿No recibiste el código?
                                <span id="resendCountdown">Podrás reenviarlo en <b>60s</b></span>
                            </span>
                            <button type="button" class="btn btn-link resend-btn" id="resendOTPBtn" disabled>
                                <i class="fa fa-refresh"></i> Reenviar código
                            </button>
                        </div>
                    </form>
                </div>

                <div class="modal-footer">
                    <button type="button" class="btn btn-default" id="exitOtpBtn">
                        <i class="fa fa-sign-out"></i> Salir
                    </button>
                </div>
            </div>
        </div>
    </div>

    <script>
        var appmob = '<?php print $_SESSION["tappmob"] ?? ''; ?>';
        var OTP_RESEND_AFTER = <?php print (int) $OTP_RESEND_AFTER_SECONDS; ?>;
    </script>
    <script src="js/a_otp.js?v=1.1"></script>
    <script>$('#userDataModal').modal('show');</script>
</body>
</html>
<?php

function maskEmail($email) {
    if (empty($email) || strpos($email, '@') === false) return $email;
    list($user, $domain) = explode('@', $email);
    $visibleUserChars   = max(2, intval(strlen($user) / 2));
    $visibleDomainChars = max(2, intval(strlen($domain) / 2));
    $maskedUser   = substr($user, 0, $visibleUserChars) . str_repeat('*', max(0, strlen($user) - $visibleUserChars));
    $maskedDomain = str_repeat('*', max(0, strlen($domain) - $visibleDomainChars)) . substr($domain, -$visibleDomainChars);
    return $maskedUser . '@' . $maskedDomain;
}

function maskTel($tel) {
    if (empty($tel)) return $tel;
    $visibleUserChars = max(2, intval(strlen($tel) / 2));
    return substr($tel, 0, $visibleUserChars) . str_repeat('*', max(0, strlen($tel) - $visibleUserChars));
}
?>
