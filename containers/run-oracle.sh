#!/bin/sh
# run-oracle.sh — esempio export da Oracle via container ora2pg:oracle
#
# Prerequisiti:
#   ./config/ora2pg.conf   (da containers/ora2pg.conf.example, sezione Opzione A)
#   ./out/                 (output export, creata se manca)
#   Immagine: ./containers/build.sh oracle
#
# Credenziali via env (mai nella config condivisa):
#   ORA2PG_USER / ORA2PG_PASSWD
#
# Sequenza reale (scommentare a turno):
#   1. schema:  TABLE -o  ->  2. psql -f schema  ->  3. COPY bulk  ->  4. INSERT incrementale
set -eu

cd "$(dirname "$0")/.."
mkdir -p config out

if [ ! -f config/ora2pg.conf ]; then
  echo "ERRORE: manca config/ora2pg.conf (copiare da containers/ora2pg.conf.example)." >&2
  exit 1
fi

: "${ORA2PG_USER:?impostare ORA2PG_USER}"
: "${ORA2PG_PASSWD:?impostare ORA2PG_PASSWD}"

# Aggiungere --no_start_scn se USER_GRANTS=1 con utente non-DBA.
EXTRA="${EXTRA:---no_start_scn}"

# 1. Export schema
podman run --rm --userns=keep-id \
  -v ./config:/config:ro -v ./out:/work \
  -e ORA2PG_USER -e ORA2PG_PASSWD \
  ora2pg:oracle -c /config/ora2pg.conf -t TABLE -b /work $EXTRA

# 2. Import schema su PG (pulire a mano eventuali CREATE INDEX indesiderati):
# psql -h pg-dest.example -U pgloader -d pdmlink -f out/ora_export_schema.sql

# 3. Bulk iniziale (WHERE/DELETE commentati in config):
# podman run --rm --userns=keep-id \
#   -v ./config:/config:ro -v ./out:/work \
#   -e ORA2PG_USER -e ORA2PG_PASSWD \
#   ora2pg:oracle -c /config/ora2pg.conf -t COPY --pg_dsn "dbi:Pg:dbname=pdmlink;host=pg-dest.example;port=5432" \
#     --pg_user pgloader --pg_pwd "$PG_PWD" -b /work $EXTRA

# 4. Incrementale (WHERE sorgente + DELETE destinazione + INSERT_ON_CONFLICT 1):
# podman run --rm --userns=keep-id \
#   -v ./config:/config:ro -v ./out:/work \
#   -e ORA2PG_USER -e ORA2PG_PASSWD \
#   ora2pg:oracle -c /config/ora2pg.conf -t INSERT --pg_dsn "dbi:Pg:dbname=pdmlink;host=pg-dest.example;port=5432" \
#     --pg_user pgloader --pg_pwd "$PG_PWD" -b /work $EXTRA
