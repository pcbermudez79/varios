/* ==========================================================================
   OTP Verification Controller
   - Auto-focus entre casillas
   - Pegar el código completo distribuye los dígitos
   - Countdown de reenvío
   - Solicitud de reenvío al backend (case 3)
   ========================================================================== */

(function ($) {
    'use strict';

    var RESEND_AFTER = (typeof OTP_RESEND_AFTER !== 'undefined' && OTP_RESEND_AFTER > 0)
        ? OTP_RESEND_AFTER : 60;

    var $inputs    = $('.code-input');
    var $verifyBtn = $('#verifyOTPCodeBtn');
    var $resendBtn = $('#resendOTPBtn');
    var $countdown = $('#resendCountdown');
    var $hint      = $('#resendHint');
    var $error     = $('#otpError');
    var $info      = $('#infoLabel');
    var $exitBtn   = $('#exitOtpBtn');

    var countdownTimer = null;

    /* ---------- Helpers ---------- */

    function getCode() {
        var code = '';
        $inputs.each(function () { code += ($(this).val() || '').replace(/\D/g, ''); });
        return code;
    }

    function setError(msg) {
        if (!msg) {
            $error.removeClass('is-visible').text('');
            $inputs.removeClass('is-error');
            return;
        }
        $error.text(msg).addClass('is-visible');
        $inputs.addClass('is-error');
        setTimeout(function () { $inputs.removeClass('is-error'); }, 600);
    }

    function updateVerifyState() {
        $verifyBtn.prop('disabled', getCode().length !== 6);
    }

    function focusFirst() { setTimeout(function () { $inputs.eq(0).focus(); }, 250); }

    function clearInputs() {
        $inputs.val('').removeClass('is-filled');
        updateVerifyState();
        focusFirst();
    }

    function fillFromString(str) {
        var digits = (str || '').replace(/\D/g, '').slice(0, 6).split('');
        if (digits.length === 0) return;
        $inputs.each(function (i) {
            var v = digits[i] || '';
            $(this).val(v).toggleClass('is-filled', v !== '');
        });
        var next = digits.length < 6 ? digits.length : 5;
        $inputs.eq(next).focus();
        updateVerifyState();
    }

    /* ---------- Countdown de reenvío ---------- */

    function startResendCountdown(seconds) {
        clearInterval(countdownTimer);
        var remaining = seconds;

        $resendBtn.prop('disabled', true);
        $hint.show();
        $countdown.html('Podrás reenviarlo en <b>' + remaining + 's</b>');

        countdownTimer = setInterval(function () {
            remaining--;
            if (remaining <= 0) {
                clearInterval(countdownTimer);
                $countdown.text('');
                $hint.hide();
                $resendBtn.prop('disabled', false);
                return;
            }
            $countdown.html('Podrás reenviarlo en <b>' + remaining + 's</b>');
        }, 1000);
    }

    /* ---------- Input handling ---------- */

    $inputs.on('input', function (e) {
        var $this = $(this);
        var val = ($this.val() || '').replace(/\D/g, '');

        // Si el usuario escribe más de un dígito (autofill / paste inline)
        if (val.length > 1) {
            fillFromString(val);
            return;
        }

        $this.val(val).toggleClass('is-filled', val !== '');

        if (val && $this.next('.code-input').length) {
            $this.next('.code-input').focus();
        }
        setError('');
        updateVerifyState();
    });

    $inputs.on('keydown', function (e) {
        var $this = $(this);
        var key = e.key;

        if (key === 'Backspace' && !$this.val() && $this.prev('.code-input').length) {
            $this.prev('.code-input').focus();
            return;
        }
        if (key === 'ArrowLeft' && $this.prev('.code-input').length) {
            e.preventDefault();
            $this.prev('.code-input').focus();
        }
        if (key === 'ArrowRight' && $this.next('.code-input').length) {
            e.preventDefault();
            $this.next('.code-input').focus();
        }
        if (key === 'Enter') {
            e.preventDefault();
            if (getCode().length === 6) $verifyBtn.click();
        }
    });

    $inputs.on('paste', function (e) {
        e.preventDefault();
        var text = '';
        var cd = e.originalEvent && e.originalEvent.clipboardData;
        if (cd) text = cd.getData('text');
        else if (window.clipboardData) text = window.clipboardData.getData('Text');
        fillFromString(text);
    });

    $inputs.on('focus', function () { this.select(); });

    /* ---------- Verificar código ---------- */

    $verifyBtn.on('click', function () {
        var code = getCode();
        if (code.length !== 6) {
            setError('Ingresa los 6 dígitos del código.');
            return;
        }

        setError('');
        $verifyBtn.prop('disabled', true).addClass('is-loading');

        $.ajax({
            url: 'a_otpauth.php',
            method: 'POST',
            dataType: 'json',
            data: {
                step: 1,
                ccod: $('#ccod').val(),
                code: code
            }
        }).done(function (resp) {
            if (resp && resp.success) {
                // Solicitar login final (case 2)
                $.ajax({
                    url: 'a_otpauth.php',
                    method: 'POST',
                    dataType: 'json',
                    data: { step: 2, ccod: $('#ccod').val() }
                }).done(function (r2) {
                    if (r2 && r2.success) {
                        window.location.href = 'a_home.php?key=' + encodeURIComponent(r2.key);
                    } else {
                        setError((r2 && r2.message) || 'No se pudo iniciar sesión.');
                        $verifyBtn.prop('disabled', false).removeClass('is-loading');
                    }
                }).fail(function () {
                    setError('Error de red. Intenta nuevamente.');
                    $verifyBtn.prop('disabled', false).removeClass('is-loading');
                });
                return;
            }

            $verifyBtn.removeClass('is-loading');
            setError((resp && resp.message) || 'Código inválido.');

            if (resp && (resp.expired || resp.blocked)) {
                // Habilitar reenvío inmediato si expiró o se bloqueó
                clearInterval(countdownTimer);
                $countdown.text('');
                $hint.hide();
                $resendBtn.prop('disabled', false);
            }
            clearInputs();
        }).fail(function () {
            setError('Error de red. Intenta nuevamente.');
            $verifyBtn.prop('disabled', false).removeClass('is-loading');
        });
    });

    /* ---------- Reenviar código ---------- */

    $resendBtn.on('click', function () {
        var $btn = $(this);
        $btn.prop('disabled', true).addClass('is-loading');
        setError('');

        $.ajax({
            url: 'a_otpauth.php',
            method: 'POST',
            dataType: 'json',
            data: { step: 3, ccod: $('#ccod').val() }
        }).done(function (resp) {
            $btn.removeClass('is-loading');
            if (resp && resp.success) {
                $info.html(resp.message || 'Se envió un nuevo código.').removeClass('alert-danger').addClass('alert-info');
                clearInputs();
                startResendCountdown(resp.resend_after || RESEND_AFTER);
            } else {
                setError((resp && resp.message) || 'No se pudo reenviar el código.');
                if (resp && resp.wait) startResendCountdown(resp.wait);
                else $btn.prop('disabled', false);
            }
        }).fail(function () {
            $btn.removeClass('is-loading').prop('disabled', false);
            setError('Error de red al reenviar. Intenta nuevamente.');
        });
    });

    /* ---------- Salir ---------- */

    $exitBtn.on('click', function () {
        window.location.href = 'a_login.php';
    });

    /* ---------- Init ---------- */

    $('#userDataModal').on('shown.bs.modal', focusFirst);
    focusFirst();
    startResendCountdown(RESEND_AFTER);

}(jQuery));
