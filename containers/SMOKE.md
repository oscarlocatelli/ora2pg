# SMOKE test immagini ora2pg (Podman, host RHEL10-compatibile)

Validazione senza DB vero (§7 del piano): i test devono fallire solo per
connessione, mai per driver mancante. Piattaforma obbligatoria: `linux/amd64`.

## 0. Prerequisiti

- Podman recente (`podman --version`), contesto root del repo.
- Target `mssql`: accesso a `packages.microsoft.com` (repo RHEL10).
- Target `oracle`: i 4 RPM 19.27 el9 in `vendor/oracle-instantclient/`
  (basic+devel+sqlplus installati, jdbc escluso — vedi `vendor/oracle-instantclient/README.md`).

## 1. Build

```sh
./containers/build.sh mssql
./containers/build.sh oracle   # richiede gli RPM
```

Entrambi devono uscire 0. Il Dockerfile fallisce da solo se:
- `ldd libclntsh` riporta `not found` (rischio el9-su-el10),
- `perl -MDBD::Oracle` / `perl -MDBD::ODBC` non caricano il driver,
- `odbcinst -q -d` non mostra `msodbcsql18`.

## 2. Smoke oracle (§7.2)

```sh
podman run --rm ora2pg:oracle ora2pg --version
podman run --rm --entrypoint perl ora2pg:oracle -MDBD::Oracle -MDBD::Pg -e 'print "drivers ok\n"'
podman run --rm --entrypoint sh ora2pg:oracle -c 'ldd $ORACLE_HOME/lib/libclntsh.so* | grep -c "not found" || echo "ldd pulito"'
podman run --rm --entrypoint sqlplus ora2pg:oracle -v
```

## 3. Smoke mssql (§7.3)

```sh
podman run --rm ora2pg:mssql ora2pg --version
podman run --rm --entrypoint odbcinst ora2pg:mssql -q -d
# atteso: [msodbcsql18] con Driver=/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18.*.so.1.1
podman run --rm --entrypoint perl ora2pg:mssql -MDBD::ODBC -MDBD::Pg -e 'print "drivers ok\n"'
```

## 4. Dry-run SHOW_VERSION (§7.4/§7.6, entrambe le varianti)

```sh
cp containers/ora2pg.conf.example config/ora2pg.conf   # poi personalizzare DSN
podman run --rm -v ./config:/config:ro ora2pg:oracle -c /config/ora2pg.conf -t SHOW_VERSION
podman run --rm -v ./config:/config:ro ora2pg:mssql  -c /config/ora2pg.conf -t SHOW_VERSION --mssql
```

Esito atteso: errore di **connessione** (host inesistente / login), MAI
`Can't locate DBD/...`, `DBI connect ... driver`, `Data source name not found`
o simili. Quell'errore prova che lo stack driver è caricato.

## 5. Versioni pinnate (aggiornare a ogni build riuscita)

Verificate il 2026-09-07 con `UBI_TAG=10.2` (build `mssql` + `oracle` riuscite,
tutti gli smoke §2–§4 verdi):

| Componente              | Versione        | Note                        |
|-------------------------|-----------------|-----------------------------|
| `UBI_TAG`               | 10.2            | `ARG` in Containerfile      |
| Ora2Pg                  | v25.0           | da sorgente repo            |
| `ora2pg:mssql`          | **156 MB**      | era 612 MB prima dello split build/final |
| `ora2pg:oracle`         | **399 MB**      | era 1.08 GB (idem + Instant Client ~55 MB) |
| `msodbcsql18`           | 18.6.2.1-1      | implicito via repo rhel/10  |
| `.so` driver            | `libmsodbcsql-18.6.so.2.1` | NON `.so.1.1` come nelle doc vecchie |
| `DBD::ODBC` (CPAN)      | 1.61            | via cpanm in `build-mssql`  |
| `DBD::Oracle` (CPAN)    | 1.95            | via cpanm in `build-oracle` |
| `perl-DBD-Pg` (RPM UBI) | 3.18.0          | niente CPAN                 |
| Instant Client          | 19.27 el9       | RPM utente in `vendor/`, non committati |

Dieta ottenuta con: stage `build-*` separati (toolchain fuori dalle finali),
`perl-interpreter` al posto del metapacchetto `perl` (che trascina
`perl-devel` → `gcc` → toolchain, +109 MB di solo gcc), moduli core espliciti
(`perl-Benchmark`, `perl-IO`, … — mappati con `rpm -qf` sul builder), RPM
Oracle fuori da `lib/` (MakeMaker li installava come moduli Perl: +54 MB
spuri in `/usr/local/share/perl5`).

## 6. Troubleshooting

- `rpm -Uvh /tmp/oracle/*.rpm` → "no such file": la directory
  `vendor/oracle-instantclient/` non contiene RPM. Procurarli come da
  `vendor/oracle-instantclient/README.md` e rebuildare.
- `libclntsh ... not found` / `ORA-` a runtime: dipendenze el9 mancanti su el10
  (`libaio`, `libnsl`, `libcrypto`). Verificare con `ldd`; `libaio`+`libnsl`
  sono già nell'immagine, `compat-openssl11` non esiste su UBI10.
- `odbcinst -q -d` vuoto: il `sed` sul Driver non ha matchato (patch `.so`
  inattesa). Ispezionare `/opt/microsoft/msodbcsql18/lib64/` e riallineare
  `containers/mssql/odbcinst.ini`.
- `USER ora2pg` + volumi: file in `out/` illeggibili → usare sempre
  `--userns=keep-id` come negli script `run-*.sh`.
- Build su arm64 (Mac M1/2): fuori scope, fallisce per mancanza di
  Instant Client/msodbcsql x64. Buildare con `--platform linux/amd64`.

## 7. Fallback Instant Client 23ai (§7.5)

Se lo smoke oracle fallisce per incompatibilità 19.x el9-su-el10:

1. Scaricare dalla pagina Oracle i 3 RPM **23ai** el10-equivalenti
   (basic+devel+sqlplus) in una directory separata (NON in
   `vendor/oracle-instantclient/` insieme ai 19.x) e puntarci la `COPY`
   dello stage `oracle`, oppure sostituire temporaneamente i file.
2. Rebuild con override del path:
   ```sh
   podman build --platform linux/amd64 -f containers/Containerfile \
     --build-arg UBI_TAG=10.2 \
     --build-arg ORACLE_HOME=/usr/lib/oracle/23.X/client64 \
     --target oracle -t ora2pg:oracle .
   ```
   (sostituire `23.X` con la dir reale creata dagli RPM).
3. Ripetere §2 + §4 e registrare qui sotto l'esito.

Esito fallback: _da compilare_.

## 8. Domande ancora aperte (dal piano, non bloccanti)

- Registry interno per `ora2pg:oracle/mssql` e policy di firma?
- `ora2pg_scanner` serve nel PATH/entrypoint alternativo?
- RPM `jdbc` 19.27 omesso: confermato che non serve a runtime?
- Client PG 16 vs `PG_VERSION 11`: ok per i target reali?
- `postgresql-contrib` serve nel container o solo sul DB destinazione?
  (attuale: omesso, solo client `psql` a bordo)
