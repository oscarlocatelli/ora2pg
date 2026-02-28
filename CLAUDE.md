# Ora2Pg - Istruzioni per Claude

## Descrizione del progetto
Ora2Pg è un tool Perl per migrare schema e dati da database Oracle (e MySQL/MSSQL) verso PostgreSQL.
Questo è un fork del progetto originale [darold/ora2pg](https://github.com/darold/ora2pg).

## Struttura del progetto

```
ora2pg/
├── scripts/ora2pg          # Script CLI principale (entry point)
├── lib/
│   ├── Ora2Pg.pm           # Modulo principale (~15000 righe), logica core di export
│   └── Ora2Pg/
│       ├── Oracle.pm       # Logica specifica Oracle (query catalogo, metadati)
│       ├── MSSQL.pm        # Logica specifica SQL Server
│       ├── MySQL.pm        # Logica specifica MySQL
│       ├── PLSQL.pm        # Conversione PL/SQL → PL/pgSQL
│       └── GEOM.pm         # Conversione tipi geometrici
├── doc/                    # Documentazione (pod, man page)
├── packaging/              # File per pacchettizzazione
├── changelog               # Storico modifiche
└── Makefile.PL             # Build system Perl
```

## Concetti chiave

### Prefisso DBA/ALL
- Con privilegi DBA: usa viste `DBA_*` (es. `DBA_TABLES`, `DBA_OBJECTS`)
- Con `USER_GRANTS=1`: usa viste `ALL_*` (es. `ALL_TABLES`, `ALL_OBJECTS`)
- Controllato da `$self->{prefix}` impostato in `Ora2Pg.pm:1598-1601`
- Auto-detection in `Oracle.pm:167-178`: se `DBA_ROLE_PRIVS` fallisce, cade su `ALL_*`

### SCN (System Change Number)
- Oracle usa SCN come timestamp logico per consistenza snapshot
- Ora2Pg recupera automaticamente l'SCN corrente per export dati (`AS OF SCN`)
- Richiede accesso a `v$database` (privilegio `SELECT ANY DICTIONARY`)
- `--no_start_scn`: disabilita il recupero automatico SCN
- `--scn <numero>`: usa un SCN specifico (alternativa per utenti non privilegiati)

### Tipi di export (TYPE)
- Schema: `TABLE`, `VIEW`, `SEQUENCE`, `FUNCTION`, `PROCEDURE`, `TRIGGER`, `GRANT`, ecc.
- Dati: `INSERT`, `COPY` (copia dati effettivi)
- Analisi: `TEST`, `TEST_DATA`, `SHOW_TABLE`, ecc.

## Problemi noti: query con privilegi hardcoded

### v$database (SCN) — NON protette da USER_GRANTS
- `Ora2Pg.pm:9628` — SCN automatico per export dati (risolvibile con `--no_start_scn`)
- `Ora2Pg.pm:10026` — SCN per CDC
- `Oracle.pm:205` — solo se `oracle_scn=current`

### _get_privilege() — DBA hardcoded senza guard
La funzione `Oracle.pm:2675-2802` usa viste DBA senza rispettare `user_grants`:
- `DBA_TAB_PRIVS` + `DBA_OBJECTS` (riga 2683)
- `DBA_COL_PRIVS` + `DBA_OBJECTS` (riga 2722)
- `DBA_SYS_PRIVS` (riga 2760)
- `DBA_ROLE_PRIVS` (riga 2773)
- `DBA_USERS` (riga 2781)
- `DBA_ROLES` (riga 2790)

### Query correttamente protette
- `_get_database_size()`: usa `USER_SEGMENTS` con `user_grants=1`
- `_get_tablespaces()` / `_list_tablespaces()`: guard in `Ora2Pg.pm` che blocca l'esecuzione
- `_get_audit_queries()`: guard in `Ora2Pg.pm` che blocca l'esecuzione

## Convenzioni di sviluppo
- Linguaggio: Perl
- I file `.pm` sono molto grandi — leggere solo le sezioni necessarie
- Le modifiche a `Ora2Pg.pm` e `Oracle.pm` devono rispettare il pattern `$self->{prefix}` per le viste catalogo
- Testare sempre con `USER_GRANTS=1` per verificare che utenti non-DBA non incontrino errori
