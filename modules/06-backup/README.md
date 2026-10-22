# 06-backup — pgBackRest checks & pre-patch snapshot

| Script | Purpose |
|---|---|
| `pgbackrest-validate.sh [--env conf/site.env]` | Stanza check, repo info, latest backup, backup verify, WAL archive continuity. Read-only. |
| `take-prepatch-snapshot.sh [--env conf/site.env]` | Checks the EPAS service is up, validates the stanza, takes a tagged backup and lists it — run before patching. |

Settings: `STANZA` (in `conf/site.env`, default `main`); optional environment overrides `BACKUP_TYPE` (default `full`) and `SNAPSHOT_TAG`. The EPAS service name comes from `EPAS_VERSION`.
