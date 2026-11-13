# EPAS major upgrade: rehearsal sheet

Run `docs/epas-major-upgrade-efm.md` once on a spare or small database before the real window, and fill this in.
A rehearsal answers three things: **do the scripts work on a real server**, **how long does each step take**,
and **what surprised us**. None of the new Track A scripts has run on a real EPAS server yet.

## Setup
| | |
|---|---|
| Date / who | |
| Server(s), OS | |
| Database size (data directory, GB) | |
| Old to new version | |
| TDE on? | |
| EFM cluster (primary + standby, no VIP) or single node? | |
| Toolkit version (`git describe`) | |

## Times to record
These numbers set the real window and the standby gap. The 14 to 17 reference is about 200 GB in just under 60 minutes for `pg_upgrade` alone.

| Step (runbook number) | Started | Finished | Minutes | Notes |
|---|---|---|---|---|
| 3 `epas-major-pgupgrade.sh`: preflight and `pg_upgrade --check` | | | | |
| 3 `pg_upgrade --copy-by-block` | | | | |
| 3 statistics rebuild (`vacuumdb --analyze-in-stages`) | | | | |
| 7 `epas-rebuild-standby.sh` (copy over the network) | | | | |
| 9 `epas-post-upgrade-backup.sh`: first backup | | | | |
| 10 restore test | | | | |
| **Gap with no standby** (end of step 6 to standby streaming) | | | | |

Do not guess the 15 TB figure from 200 GB: the standby gap and the post-upgrade backup grow with size.

## Checks on the real server (each answers an open item)
| # | Check | Result |
|---|---|---|
| 1 | The TDE preflight in the upgrade script: does it find the pass file and say the old and new passphrases match? | |
| 2 | `grep unwrap` on the new `postgresql.conf`: is `data_encryption_key_unwrap_command` there as expected, pointing outside the data directory? | |
| 3 | `epas-rebuild-standby.sh`: version check, space check and TDE check all print and pass | |
| 4 | Is the passphrase file on the standby host **before** the rebuild? (If not, the script stops with the copy kept: record it) | |
| 5 | After the standby starts: `pg_stat_replication` on the primary shows it streaming | |
| 6 | `epas-post-upgrade-backup.sh`: old-version backups moved into `pre-upgrade-epas<old>-<time>/`; WAL archiving proved by the switch test | |
| 7 | Any file with the same name already in the WAL archive (look for "refusing to overwrite" in the toolkit log)? | |
| 8 | Restore test on the first new backup: PASS? Does `pg_verifybackup` work on a TDE backup, and does the temporary instance unwrap the key? | |
| 9 | EFM: order of stopping the agents (standby first, then primary): did it matter? What did EFM do when only one agent was stopped? | |
| 10 | After upgrade, anything else in `efm.properties` that is version-specific, beyond what `efm-reconfigure-after-upgrade.sh` sets? | |

## Problems and fixes
| What happened | Fix | Toolkit change needed? |
|---|---|---|
| | | |

## Sign-off for the real window
- [ ] Every step ran as written, or the changes are made in the toolkit and the rehearsal repeated
- [ ] Times recorded; window agreed with the application owners
- [ ] A verified backup of the old cluster exists; the passphrase file is held somewhere other than the servers (escrow)
- [ ] The old standby stays untouched until the application has written to the new primary and everyone has signed off
