# Changelog

What changed in edb_toolkit, newest first. Updated together with every change.

## Unreleased

- **Toolkit logs moved out of `/var/log`.** Each script run now writes its own file in
  `<LOG_MOUNT>/toolkit` (`/pglog/toolkit`; change it with `TOOLKIT_LOG_DIR` in `site.env`).
  The logger no longer uses `sudo` and no longer makes a log file writable by everyone;
  new files are mode 640.
  **Action on each server:** root creates the directory once, owned by the database OS user:
  `install -d -o enterprisedb -g enterprisedb -m 2750 /pglog/toolkit`. Until then the scripts
  still run, print on the screen only, and say so.
- `epas-base-build-root.sh` creates that directory on a new server (mode 2750: log files
  written by a root run get the database group, so the DBA can read them). It refuses a
  path inside a system directory such as `/var/log`.
- Messages are copied to syslog only when `TOOLKIT_SYSLOG="yes"` (it was always on).
- New unit tests for the logger (`tests/logger-unit.sh`, run by `make test` and CI).
- Scripts that are run directly are now marked executable (`tools/install.sh`,
  `epas-ssl-setup.sh`, both upgrade scripts and five others), so they no longer need
  `chmod +x` on a server.

## v1.0.0 - 2026-11-11

- Starting version: modules 01-provision to 08-tde, shared `lib/`, `conf/` templates,
  unit tests and CI lint.
- Earlier history is not kept in this repository.
