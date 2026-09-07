#!/bin/sh
# run-mssql.sh — esempio export da SQL Server via container ora2pg:mssql
#
# Prerequisiti:
#   ./config/ora2pg.conf   (da containers/ora2pg.conf.example, sezione Opzione B)
#   ./out/                 (output export, creata se manca)
#   Immagine: ./containers/build.sh mssql
#
# DIFFERENZA FONDAMENTALE: ogni comando ora2pg richiede il flag --mssql.
# DSN esempio:
#   dbi:ODBC:Driver={ODBC Driver 18 for SQL Server};Server=mssql-src.example,1433;Database=pdmlink;TrustServerCertificate=yes
set -eu

cd "$(dirname "$0")/.."
mkdir -p config out

if [ ! -f config/ora2pg.conf ]; then
  echo "ERRORE: manca config/ora2pg.conf (copiare da containers/ora2pg.conf.example)." >&2
  exit 1
fi

: "${ORA2PG_USER:?impostare ORA2PG_USER}"
: "${ORA2PG_PASSWD:?impostare ORA2PG_PASSWD}"

EXTRA="${EXTRA:---no_start_scn}"

# 1. Export schema (notare --mssql obbligatorio)
podman run --rm --userns=keep-id \
  -v ./config:/config:ro -v ./out:/work \
  -e ORA2PG_USER -e ORA2PG_PASSWD \
  ora2pg:mssql -c /config/ora2pg.conf -t TABLE -b /work --mssql $EXTRA

# 2. Import schema su PG:
# psql -h pg-dest.example -U pgloader -d pdmlink -f out/ora_export_schema.sql

# 3. Bulk iniziale con WHERE MSSQL commentati (DATEADD, non SYSDATE):
# podman run --rm --userns=keep-id \
#   -v ./config:/config:ro -v ./out:/work \
#   -e ORA2PG_USER -e ORA2PG_PASSWD \
#   ora2pg:mssql -c /config/ora2pg.conf -t COPY --pg_dsn "dbi:Pg:dbname=pdmlink;host=pg-dest.example;port=5432" \
#     --pg_user pgloader --pg_pwd "$PG_PWD" -b /work --mssql $EXTRA

# 4. Incrementale (WHERE DATEADD(HOUR,-3,GETDATE()) + INSERT_ON_CONFLICT 1):
# podman run --rm --userns=keep-id \
#   -v ./config:/config:ro -v ./out:/work \
#   -e ORA2PG_USER -e ORA2PG_PASSWD \
#   ora2pg:mssql -c /config/ora2pg.conf -t INSERT --pg_dsn "dbi:Pg:dbname=pdmlink;host=pg-dest.example;port=5432" \
#     --pg_user pgloader --pg_pwd "$PG_PWD" -b /work --mssql $EXTRA
