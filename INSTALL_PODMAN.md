# ora2pg in container (Podman) — installazione, prova e crontab

Guida operativa validata su Rocky Linux 9. Immagini UBI10 (solo `linux/amd64`):
`ora2pg:oracle` (~399 MB, export da Oracle) e `ora2pg:mssql` (~156 MB,
export da SQL Server). Dettagli build e versioni pinnate: `containers/SMOKE.md`.

## 1. Installare podman (Rocky 9)

```bash
sudo dnf install -y podman
podman --version
```

## 2. Procurarsi le immagini

**A. Con internet:** clonare il repo, copiare i 4 RPM Instant Client 19.27
in `vendor/oracle-instantclient/` (vedi `vendor/oracle-instantclient/README.md`,
licenza OTN, mai committati) e buildare:

```bash
./containers/build.sh mssql
./containers/build.sh oracle
```

> Gli RPM servono **solo per la build**: una volta costruita, l'immagine
> `ora2pg:oracle` li contiene già (installati in `/usr/lib/oracle/...`) e a
> runtime non serve copiarli da nessuna parte. Se hai importato l'immagine
> col metodo B, questo punto non ti riguarda affatto. Il motivo per cui non
> sono nel repo git è solo la licenza OTN Oracle, che ne vieta la
> ridistribuzione: chi builda li deve procurare in locale.

**B. Senza internet:** buildare su un'altra macchina e trasferire:

```bash
# macchina con internet
podman save -o ora2pg-oracle.tar localhost/ora2pg:oracle
podman save -o ora2pg-mssql.tar localhost/ora2pg:mssql
# macchina di produzione
podman load -i ora2pg-oracle.tar
podman load -i ora2pg-mssql.tar
```

> Rootless e root hanno storage separati: caricare le immagini con lo stesso
> utente che eseguirà i container (i job sotto girano da root).

## 3. Preparare directory e permessi (punto critico)

Le immagini girano come `USER ora2pg`. Tutto ciò che ora2pg deve scrivere
(`LOGFILE`, `OUTPUT`, dir di lavoro) deve essere scrivibile da quell'utente.
La via più semplice per job da root è aggiungere `--user root` ai comandi
(così i file restano di root come nell'installazione classica). Alternativa:
`chown` delle directory/file sull'UID del container
(`podman run --rm --entrypoint id ora2pg:oracle`).

```bash
mkdir -p /root/out
touch /var/log/ora2pg_pdm_container.log
```

Regole per i mount (Rocky ha SELinux enforcing, serve il suffisso `,z`;
`--userns=keep-id` serve solo rootless, **mai** con `--network=host` da root):

- config: `-v /etc/ora2pg/<conf>:/config/ora2pg.conf:ro,z`
- lavoro/output: `-v /root/out:/work:z`
- log su path assoluto del `.conf`: montare il file,
  `-v /var/log/ora2pg_pdm_container.log:/var/log/ora2pg_pdm.log:z`
  (se il path host non esiste, podman crea una _directory_ e il log fallisce:
  creare prima il file con `touch`).

Rete: per job batch verso DB sull'host/LAN usare `--network=host`, così
`127.0.0.1` nel `.conf`/DSN continua a significare l'host ( dentro il
container senza `--network=host` sarebbe il container stesso: in quel caso
usare `host.containers.internal`, e Postgres deve accettare connessioni
non-loopback in `listen_addresses`/`pg_hba.conf`).

## 4. Prova (smoke senza scrivere nulla)

```bash
export ORA2PG_USER=<user> ORA2PG_PASSWD='<password>'  # se non nel .conf
podman run --rm --network=host --user root \
  -v /etc/ora2pg/ora2pg_pdm_INSERT.conf:/config/ora2pg.conf:ro,z \
  -e ORA2PG_USER -e ORA2PG_PASSWD \
  ora2pg:oracle -c /config/ora2pg.conf -t SHOW_VERSION --no_start_scn
```

Esito atteso: la versione Oracle (connessione OK) oppure un errore di sola
connessione (`ORA-12545`/`ORA-12154`). Variante MSSQL (notare: con `--mssql`
e **senza** `--no_start_scn`):

```bash
podman run --rm --network=host --user root \
  -v /etc/ora2pg/ora2pg_pdm_INSERT_mssql.conf:/config/ora2pg.conf:ro,z \
  -e ORA2PG_USER -e ORA2PG_PASSWD \
  ora2pg:mssql -c /config/ora2pg.conf -t SHOW_VERSION --mssql
```

Regola MSSQL: immagine `ora2pg:mssql` **+** flag `--mssql` sempre **+** DSN
ODBC (`Opzione B` del `containers/ora2pg.conf.example`).

## 5. Uso reale (equivalente del comando host)

Host: `ora2pg -c ... -t INSERT --no_start_scn --pg_dsn "dbi:Pg:..."`
→ container (flock/nice restano sull'host, il nice viene ereditato):

```bash
flock -n /var/lock/ora2pg.lock nice -n 8 podman run --rm --network=host --user root \
  -v /etc/ora2pg/ora2pg_pdm_INSERT.conf:/config/ora2pg.conf:ro,z \
  -v /root/out:/work:z \
  -v /var/log/ora2pg_pdm_container.log:/var/log/ora2pg_pdm.log:z \
  ora2pg:oracle -c /config/ora2pg.conf -t INSERT --no_start_scn \
  --pg_dsn "dbi:Pg:dbname=pdm;host=127.0.0.1;port=5432"
```

Variante MSSQL (stesso schema, `--mssql` al posto di `--no_start_scn`):

```bash
flock -n /var/lock/ora2pg.lock nice -n 8 podman run --rm --network=host --user root \
  -v /etc/ora2pg/ora2pg_pdm_INSERT_mssql.conf:/config/ora2pg.conf:ro,z \
  -v /root/out:/work:z \
  -v /var/log/ora2pg_pdm_container.log:/var/log/ora2pg_pdm.log:z \
  ora2pg:mssql -c /config/ora2pg.conf -t INSERT --mssql \
  --pg_dsn "dbi:Pg:dbname=pdm;host=127.0.0.1;port=5432"
```

## 6. Crontab (traduzione 1:1 dei job esistenti)

```cron
#
# ORA2PG PROD (container)
#
#2026-02-28 O.Locatelli - Allineamento periodico (non bloccante)
*/20 * * * * root flock -n /var/lock/ora2pg.lock nice -n 8 /usr/bin/podman run --rm --network=host --user root -v /etc/ora2pg/ora2pg_pdm_INSERT.conf:/config/ora2pg.conf:ro,z -v /root/out:/work:z -v /var/log/ora2pg_pdm_container.log:/var/log/ora2pg_pdm.log:z ora2pg:oracle -c /config/ora2pg.conf -t INSERT --no_start_scn --pg_dsn dbi:Pg:dbname=pdm;host=127.0.0.1;port=5432
#
#2026-03-09 O.Locatelli - Allineamento notturno con DELETE ORPHANS (bloccante)
00  20  *  *  * root flock /var/lock/ora2pg.lock nice -n 8 /usr/bin/podman run --rm --network=host --user root -v /etc/ora2pg/ora2pg_pdm_DELETE_ORPHANS.conf:/config/ora2pg.conf:ro,z -v /root/out:/work:z -v /var/log/ora2pg_pdm_delete_orphans_container.log:/var/log/ora2pg_pdm.log:z ora2pg:oracle -c /config/ora2pg.conf -t INSERT --no_start_scn --pg_dsn dbi:Pg:dbname=pdm;host=sportal-tecniplast.evoloop.it;port=5432
```

Note:

- `flock` invariato sull'host: `-n` (non bloccante) per il periodico,
  bloccante per il notturno; stesso lock file = mutua esclusione anche con
  run fuori container. (Nel crontab i `;` del `--pg_dsn` vanno bene così
  com'erano: cron li passa alla shell.)
- Per sorgente MSSQL la traduzione è analoga: immagine `ora2pg:mssql`,
  flag `--mssql` al posto di `--no_start_scn` (vedi §5).
- `/usr/bin/podman` con path assoluto (cron ha `PATH` minimo).
- Credenziali: come prima (nel `.conf`, o `export` in `/etc/crontab`-style
  con `ORA2PG_USER`/`ORA2PG_PASSWD` + `-e` nel `podman run`).
- Il job notturno punta a un Postgres su altro host: con `--network=host`
  la risoluzione DNS è quella dell'host, nessuna modifica.
- Prima di attivare: `touch` dei file di log + verifica §4 per entrambi i `.conf`.

## 7. Troubleshooting rapido

| Sintomo                                                          | Causa e fix                                                                                                                        |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Solo `Aborting export...`, log vuoto, `exit=9`                   | `LOGFILE`/`OUTPUT` non scrivibili dall'utente del container (`EBADF`): aggiungere `--user root` o `chown` dei mount (vedi §3)      |
| `Can't locate DBD/ODBC.pm ... at Ora2Pg/Oracle.pm`               | Usata l'immagine `oracle` o dimenticato `--mssql` (serve `ora2pg:mssql` + `--mssql` + DSN ODBC)                                    |
| `crun: mount 'sysfs' ... Operation not permitted`                | `--userns=keep-id` da root con `--network=host`: toglierlo (serve solo rootless)                                                   |
| `permission denied` sui volumi                                   | Manca `,z` (SELinux) sui `-v`                                                                                                      |
| `Can't locate DBD/Oracle.pm`                                     | Usata l'immagine `mssql` per un DSN Oracle                                                                                         |
| `Connection refused` verso `127.0.0.1` PG senza `--network=host` | Dal container `127.0.0.1` è il container: usare `--network=host` o `host.containers.internal` (+ `listen_addresses`/`pg_hba.conf`) |
