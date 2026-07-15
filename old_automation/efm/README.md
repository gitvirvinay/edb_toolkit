# 🛡️ EFM High Availability & Clustering Module

This directory houses the infrastructure automation and orchestration tools for managing EnterpriseDB (EDB) Failover Manager (EFM) environments. Keeping EFM decoupled from the core database engine ensures clear boundaries for high-availability lifecycle management.

---

## 📂 Module Tree

```text
/u001/automation/efm/
├── README.md                  # This operational runbook and execution guide
├── efm-rolling-upgrade.sh     # Bare-metal rolling upgrade utility (Java 11 & VIP handling)
└── efm-cluster-status.sh      # Standardized cluster health observability wrapper


[ STEP 1 ]                [ STEP 2 ]               [ STEP 3 ]
Standby Nodes   ───>   Witness Node(s)   ───>   Primary Node
(Upgrade First)        (If Applicable)          (Upgrade LAST)