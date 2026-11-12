#!/bin/sh
# R2-14: separa el usuario PROPIETARIO del esquema (POSTGRES_USER, corre las migraciones de Flyway)
# del usuario de la APLICACIÓN (APP_DB_USER), que no puede crear ni alterar tablas. Los permisos sobre
# las tablas (y la prohibición de UPDATE/DELETE en security_audit) los otorgan las migraciones.
# Se ejecuta una sola vez, al crear el volumen de datos (docker-entrypoint-initdb.d).
set -eu
: "${APP_DB_USER:?Define APP_DB_USER}"
: "${APP_DB_PASSWORD:?Define APP_DB_PASSWORD}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_user="$APP_DB_USER" -v app_password="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
-- Nadie más que el propietario crea objetos en el esquema público.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
echo "Rol de aplicación $APP_DB_USER listo en $POSTGRES_DB"
