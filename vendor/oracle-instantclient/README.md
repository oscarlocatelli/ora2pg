# Oracle Instant Client RPM (contesto locale, NON committare)

Il target `oracle` del Containerfile installa l'Instant Client dai RPM in
questa directory. Per vincoli di licenza OTN gli RPM non sono nel repo git
(`lib/oracle-instantclient/` e' interamente in `.gitignore`) e le immagini
buildate sono solo per uso interno.

## Dove scaricarli

Download riservato dal sito Oracle (account OTN richiesto):
https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html

Serie usata e testata: **19.27 el9 x86_64**.

## File attesi in questa directory

- `oracle-instantclient19.27-basic-19.27.0.0.0-1.el9.x86_64.rpm`
- `oracle-instantclient19.27-devel-19.27.0.0.0-1.el9.x86_64.rpm`
- `oracle-instantclient19.27-sqlplus-19.27.0.0.0-1.el9.x86_64.rpm`
- `oracle-instantclient19.27-jdbc-...rpm` (presente ma **escluso** dal build:
  serve solo a Java, non a DBD::Oracle/sqlplus — risposta alla domanda aperta
  n.3 del piano).

Il Containerfile installa con `rpm -Uvh` tutti gli RPM presenti **tranne**
`-jdbc-` (microdnf su UBI10 non installa RPM locali per path).

## Path fissato

- Install path RPM: `/usr/lib/oracle/19.27/client64`
- `ORACLE_HOME=/usr/lib/oracle/19.27/client64`
- `LD_LIBRARY_PATH=/usr/lib/oracle/19.27/client64/lib`

Se si usa una versione diversa (es. fallback 23ai, vedi `SMOKE.md`),
passare `--build-arg ORACLE_HOME=/usr/lib/oracle/<ver>/client64`.

## Nota el9-su-el10

I pacchetti el9 girano su base UBI10 (glibc 2.39) senza certificazione
Oracle (19c certificato fino a RHEL9). Il build fallisce da solo se `ldd`
su `libclntsh` riporta librerie mancanti; in tal caso vedere `SMOKE.md`
§ troubleshooting e valutare il fallback a Instant Client 23ai
(compatibile comunque con DB 19c/12c).
