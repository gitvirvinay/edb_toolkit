# Major upgrade of an EFM cluster (primary + one standby, no VIP)

For EPAS 15 to 17 with `modules/04-upgrade/epas-major-pgupgrade.sh`, on a cluster managed by EFM.
This is the order used for 14 to 17, written down. The old standby stays on the old version until you
sign off: it is the way back.

**Point of no return:** the moment the application starts writing to the new primary. Until then
you can go back by starting the old primary, or by promoting the old standby. After that, going
back loses everything written since.

## Before the window
1. Fresh backup of the old cluster, verified (the script asks you to confirm).
2. New cluster already built and initialised on the primary (`01-provision`), same TDE passphrase setup.
3. A copy of the EFM properties file made ready for EPAS 17 (or plan to use step 6 below).
4. Rehearsed once on a copy; note the `pg_upgrade` time.

## In the window
| # | Step | Where | How |
|---|------|-------|-----|
| 1 | Stop the EFM agents (standby first, then primary) | both nodes | `systemctl stop <efm unit>`; check with `efm_agents_running` (the upgrade script refuses to run if one is active) |
| 2 | Stop the old standby's EPAS and **leave its data alone** | standby | It is your way back. Do not rebuild it yet. |
| 3 | Upgrade | primary | `epas-major-pgupgrade.sh` (check, stop old and new, `pg_upgrade --copy-by-block` for TDE, carry pg_hba/SSL, start new, rebuild statistics) |
| 4 | Validate with the application | primary | Application up, tests pass. If it fails here, go back (see the point of no return above). |
| 5 | Put the EPAS 17 properties file in place | primary | `modules/05-efm/efm-reconfigure-after-upgrade.sh` (backs the file up, sets `db.bin`, `db.data.dir`, `db.port`, `db.service.name`, `db.config.dir`) or your prepared file |
| 6 | Start EFM on the primary only | primary | `systemctl start <efm unit>`; `efm-cluster-status.sh` shows one node. No VIP, so nothing else to move. |
| 7 | Rebuild the standby on EPAS 17 | standby | New binaries; `pg_basebackup -h <primary> -U replicator -p <port> -D $PGDATA -Fp -Xs -P -R --checkpoint=fast`; start; check replication on the primary |
| 8 | Add the standby to EFM | primary, then standby | `efm allow-node <cluster> <standby ip>` on the primary; EPAS 17 properties on the standby (step 5 script); start the agent; `efm-cluster-status.sh` shows two nodes UP |
| 9 | Start a new WAL archive and take the first EPAS 17 backup | primary | The EPAS 15 backups cannot be restored on 17. `06-backup`: enable-wal-archiving, take-basebackup |
| 10 | Run the restore test once on the new backup | primary | `restore-test.sh` |

## After sign-off
Remove the old cluster (`/tmp/delete_old_cluster.sh` if generated) and the old standby's data
directory. Do this last: until then they are your way back.

## Things to know
- Between step 6 and step 8 there is **no standby**: no failover. For a 200 GB database that is
  about an hour or two. For a very large one it can be days, and is a reason to plan it differently.
- The standby rebuild in step 7 copies every byte over the network.
- TDE: the new standby needs the same wrap/unwrap setup and passphrase file as the new primary.
