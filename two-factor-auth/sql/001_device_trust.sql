-- =============================================================================
-- 2FA — Trusted Device Migration
-- Añade la tabla a_userdev y los parámetros de política OTP en e_customer.
-- =============================================================================

BEGIN;

-- Dispositivos confiables por usuario
CREATE TABLE IF NOT EXISTS a_userdev (
    codigo_dev    bigserial PRIMARY KEY,
    codigo_usy    numeric NOT NULL,
    hash_dev      varchar(64) NOT NULL,          -- sha256 del UUID de la cookie 'did'
    useragent_dev varchar,
    ip_dev        varchar(45),
    feccre_dev    timestamp(0) without time zone NOT NULL DEFAULT current_timestamp,
    fecult_dev    timestamp(0) without time zone,  -- último OTP validado en este device
    codigo_est    numeric DEFAULT 1                -- 1=activo, 2=revocado
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_a_userdev_usy_hash
    ON a_userdev (codigo_usy, hash_dev);

CREATE INDEX IF NOT EXISTS ix_a_userdev_usy_est
    ON a_userdev (codigo_usy, codigo_est);

COMMENT ON TABLE  a_userdev             IS 'Dispositivos confiables para la política de OTP con periodo de gracia';
COMMENT ON COLUMN a_userdev.hash_dev    IS 'SHA256 del UUID guardado en la cookie firmada "did"';
COMMENT ON COLUMN a_userdev.fecult_dev  IS 'Fecha del último OTP validado desde este dispositivo';
COMMENT ON COLUMN a_userdev.codigo_est  IS '1=activo, 2=revocado';

-- Parámetros de política OTP a nivel de cliente
ALTER TABLE e_customer
    ADD COLUMN IF NOT EXISTS otpfrq_cli numeric DEFAULT 1,
    ADD COLUMN IF NOT EXISTS otpmin_cli numeric DEFAULT 60;

COMMENT ON COLUMN e_customer.otpfrq_cli IS 'Política OTP: 1=always (siempre), 2=grace (omitir si el dispositivo validó dentro de otpmin_cli minutos)';
COMMENT ON COLUMN e_customer.otpmin_cli IS 'Minutos de gracia sin volver a pedir OTP (aplica cuando otpfrq_cli=2). Default 60.';

COMMIT;
