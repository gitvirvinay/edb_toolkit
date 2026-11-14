# Ansible readiness

Ansible logs into many servers over SSH and runs a task on each, from one playbook. It is planned for late next year.
Nobody sits at the keyboard, so a script it runs must behave the same with no person present.
This page is the contract, and which scripts meet it today.

## The contract

| Rule | Why |
|---|---|
| **Pass `--yes`.** No question may wait for a typed answer. Without a terminal the scripts already proceed, but a playbook should still say `--yes` (some setups give SSH a terminal, and then the question would hang). | A question nobody answers hangs the run. |
| **`sudo -n` for every sudo call.** If a sudoers rule is missing, it fails at once with a clear message. | A password prompt hangs, or fails with an unclear error. |
| **Exit code 0 only when the job is really done.** Non-zero means stop and look. | Ansible stops a host on a non-zero exit and, in a rolling run, does not go on to the next host. |
| **Exit code 2 means "done, but not confirmed".** Used where the database is up but a check did not confirm it. | A person must look before the next node is touched. |
| **Safe to run again.** A retry after a failure must not undo or confuse the first run. | Ansible re-runs tasks. |
| **Say what you did.** Every change writes a line in the toolkit log, and the audit line is only written on success. | The log is the evidence afterwards. |

## Status by script

| Area | Status |
|---|---|
| Patching: `node-maintenance-stop.sh`, `node-maintenance-start.sh` | **Ready** (v3.2.0): `sudo -n`; exit 0 / 1 / 2 as above; the note of the package version survives a retry |
| Backup: `take-basebackup.sh`, `enable-wal-archiving.sh`, `archive-wal.sh`, `restore-test.sh` | Not checked yet |
| Upgrade: `epas-major-pgupgrade.sh` and friends | **Not ready:** asks "Have you taken a verified filesystem-level backup?" and reads the TDE passphrase from the keyboard |
| EFM: `efm-setup.sh`, `efm-reconfigure-after-upgrade.sh` | **Not ready:** `efm-setup.sh` asks questions and reads the database password from the keyboard |
| Build: `epas-base-build-db.sh`, `generate-site-env.sh`, `epas-ssl-setup.sh` | **Not ready:** ask questions (TDE passphrase, config values, PEM path) |
| TDE: Thales scripts | Reworked in lesson 17 |

Where a script needs a secret (the TDE passphrase, a database password), the answer is a file or an environment variable
set by a vault, never a value typed or passed on the command line. That is decided per script when it is reworked.

## Rolling patching, in words

One node at a time: `node-maintenance-stop.sh --yes` -> the sysadmin's `dnf` -> `node-maintenance-start.sh --patched --yes`.
Then the next node. If any step exits non-zero, the run stops there. The most important stop is exit code 2 from the start
script: that node is up but EFM has not confirmed the cluster, so the next node must not be touched.
