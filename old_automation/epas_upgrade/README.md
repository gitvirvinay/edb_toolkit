# Major Version Upgrades (`epas_upgrade/`)

Dedicated to execution paths for processing major software generation migrations (e.g., transforming legacy EPAS 14 nodes directly up into encrypted EPAS 17 environments).

## Scripts
* [cite_start]**`epas-major-pgupgrade.sh`**: Leverages the high-speed `pg_upgrade --copy-by-block` framework to run rapid file-level shifts, converting standard instances directly to Transparent Data Encryption (TDE) targets with minimal downtime[cite: 6, 7].
* [cite_start]**`epas-major-pgrestore.sh`**: Implements logical `pg_dump` and parallel `pg_restore` pipelines, restructuring layout elements, dropping physical table fragmentation, and converting data definitions onto a clean target layout[cite: 4, 5].

## Crucial Pre-checks
* [cite_start]Always perform dry-run execution checks via the `--check` argument path before executing production-level structural modifications[cite: 9].
* [cite_start]Ensure valid backup archives are generated under `/backup/` before running upgrades[cite: 1, 7].