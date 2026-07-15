# 🔄 EPAS Minor Version Patching & Site Lifecycle Workspace

This directory contains automation utilities designed to safely patch **EDB Postgres Advanced Server (EPAS)** minor versions (e.g., upgrading from `15.2` to `15.7` or `17.1` to `17.2`) across non-standard layout architectures, as well as lifecycle orchestration scripts to isolate environment sites during scheduled OS patching windows.

---

## 📂 Module Tree

```text
/u001/automation/epas_patch/
├── README.md                      # This master patching orchestration runbook
├
│
├── primary_site/                  # Primary Site Lifecycle Management Utilities
│   ├── patch-primary-shutdown.sh  # Safely stop & disable EFM/EPAS on Primary nodes
│   └── patch-primary-startup.sh   # Safely enable & start EPAS/EFM on Primary nodes
│
└── dr_site/                       # Disaster Recovery Site Lifecycle Management Utilities
    ├── patch-dr-shutdown.sh       # Safely isolate & stop cascaded DR standbys
    └── patch-dr-startup.sh        # Safely rejoin DR standbys to the cluster
	
	
	
	## 🏁 Master Maintenance Execution Sequence

Follow this exact workflow during a combined OS patching and EPAS engine minor patch maintenance window:

### Phase 1: Controlled Environment Shutdown
1. **Isolate DR Site:** Execute `dr_site/patch-dr-shutdown.sh` across all DR nodes.
2. **Stop Primary Standbys:** Execute `primary_site/patch-primary-shutdown.sh` on all local standby nodes.
3. **Stop Primary Master LAST:** Execute `primary_site/patch-primary-shutdown.sh` on the active primary node to safely release the cluster VIP.

### Phase 2: Engine Patching & OS Maintenance
With EFM and EPAS safely stopped and disabled, the nodes are fully isolated:
1. Perform your system OS updates / reboots if required.
2. Execute the engine patch tool on each node:
   ```bash
   sudo ./epas-minor-patchupdate.sh 15
   
   
### Phase 3: Post-Patching (Bring-Up Sequence)
1. **Primary Node First:** Run `patch-primary-startup.sh` on the Primary Master to claim the VIP and establish the base engine.
2. **Primary Standbys Second:** Run `patch-primary-startup.sh` on the local standbys to sync WAL.
3. **DR Site Last:** Run `patch-dr-startup.sh` sequentially across DR nodes to resume cascaded replication blocks.