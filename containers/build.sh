#!/bin/sh
# build.sh — build immagini ora2pg (Podman, solo linux/amd64)
# Uso: ./containers/build.sh [oracle|mssql|all]   (default: all)
# Va lanciato dalla ROOT del repo. Le immagini sono solo per uso interno
# (licenze OTN Oracle / EULA Microsoft, vedi containers/oracle/README.md).
set -eu

cd "$(dirname "$0")/.."

TARGET="${1:-all}"
PLATFORM="linux/amd64"
UBI_TAG="${UBI_TAG:-10.2}"

build_one() {
  echo "==> podman build --target $1 -t ora2pg:$1 (UBI_TAG=$UBI_TAG)"
  podman build --platform "$PLATFORM" \
    -f containers/Containerfile \
    --build-arg "UBI_TAG=$UBI_TAG" \
    --target "$1" -t "ora2pg:$1" .
}

case "$TARGET" in
  oracle)
    if ! ls vendor/oracle-instantclient/*.rpm >/dev/null 2>&1; then
      echo "ERRORE: nessun RPM in vendor/oracle-instantclient/." >&2
      echo "Vedi vendor/oracle-instantclient/README.md per i pacchetti richiesti." >&2
      exit 1
    fi
    build_one oracle
    ;;
  mssql)
    echo "NOTA: il build scarica msodbcsql18 dal repo Microsoft (ACCEPT_EULA=Y a build-time, uso interno)."
    build_one mssql
    ;;
  all)
    "$0" mssql
    if ls vendor/oracle-instantclient/*.rpm >/dev/null 2>&1; then
      "$0" oracle
    else
      echo "SKIP oracle: nessun RPM in vendor/oracle-instantclient/ (vedi vendor/oracle-instantclient/README.md)."
    fi
    ;;
  *)
    echo "Uso: $0 [oracle|mssql|all]" >&2
    exit 1
    ;;
esac
