# 🚀 EPAS Cluster Initialization & Cloning Engine

This repository contains the enterprise automation toolset for deploying clean, multi-version EDB Postgres Advanced Server (EPAS) architectures, as well as managing Day 2 standby provisioning. It uses a decoupled, parameter-hydrated engine to isolate base platform installation, custom binary relocation, and cluster layouts from environmental configuration.

---

## 📂 Repository Architecture

```text
/u001/automation/epas_build/
├── README.md                  # This technical execution runbook
├── epas-base-build.sh         # Day 1: Multi-version base deployment engine
├── epas-rebuild-standby.sh    # Day 2: Standby replication & cloning utility
└── deploy.env.example         # Blueprint configuration hydration file

```

### Directory Manifest

| Script | Functional Scope | Execution Context |
| --- | --- | --- |
| `epas-base-build.sh` | Provisions fresh OS directories, infrastructure hardening, and initial core cluster initialization (`initdb`). | `root` |
| `epas-rebuild-standby.sh` | Safely wipes an unaligned node, streams a physical backup from a primary node, and hooks it into streaming replication. | `enterprisedb` (via `sudo` whitelist) |

---

## 🛠️ 1. Engine Provisioning (`epas-base-build.sh`)

### Configuration Matrix (`deploy.env`)

Before running the base deployment script, copy the template and configure your environment-specific target fields:

```bash
cp deploy.env.example dev-as17.env
vi dev-as17.env

```

Ensure the following variables align with your enterprise specifications:

* **`EPAS_VERSION`**: Major version target (15, 17, or 18).
* **`PRIMARY_PORT`**: Active network routing port for the engine cluster.
* **`BINARY_TOP`**: Hardened target directory for software binary isolation.
* **`DATA_TOP`**: Isolated target directory for `$PGDATA` clustering storage.
* **`SERVICE_NAME`**: The specific systemd service designation.

### Execution Guide

Execute the deployment runner as `root` (or via an explicit sudo privilege block), passing your hydrated environment specification file as a parameter:

```bash
sudo ./epas-base-build.sh --env dev-as17.env

```

### Automated Engine Phases:

1. **Repository Lifecycle Validation:** Automates system platform vendor package confirmation via native package management.
2. **Custom Systemd Tailing:** Dynamically isolates service initialization loops and rewrites standard systemd profiles to match custom directory paths.
3. **Enterprise Layout Hardening:** Configures isolated, separate owners for system data and database binary structures.
4. **Core Initialization:** Executes an authenticated database engine core initialization string (`initdb`) inside an isolated, empty directory stack.
5. **Modular Architecture Injection:** Injects clean, dynamic hooks for structural drop-in parameter isolation (`include_dir = 'conf.d'`).

---

## 🔄 2. Standby Rebuild Automation (`epas-rebuild-standby.sh`)

The `epas-rebuild-standby.sh` script is a consolidated operational tool designed to easily deploy or fix a streaming replication standby node. By utilizing targeted `sudo` whitelisting, database administrators can run the entire workflow under the unprivileged `enterprisedb` system account without shifting execution contexts.

### Operational Workflow

1. **Safety Check:** Validates execution context is strictly under the `enterprisedb` user account.
2. **Cluster Stop:** Shuts down the target local database instance via authorized `systemctl`.
3. **Directory Rotation:** Rotates and timestamps the old `/data` directory to safeguard against accidental data loss.
4. **Directory Re-provisioning:** Enforces strict security ownership (`enterprisedb:enterprisedb`) and permissions (`700`) on a clean directory target.
5. **Streaming Synchronization:** Executes an online `pg_basebackup` against the designated primary engine, auto-generating replication slots and the `standby.signal` file via `-R`.
6. **Recovery Validation:** Formally inspects configuration blocks to ensure the node is ready to assume a standby recovery persona.
7. **Cluster Start:** Boots up the replica engine and outputs real-time monitoring blocks.

---

## 🔐 Prerequisites & Infrastructure Setup

### OS-Level Sudo Whitelisting

To allow the unprivileged `enterprisedb` system user to orchestrate local directory rotations and systemd service lifecycles seamlessly during standby operations, deploy the following rules into your `/etc/sudoers.d/epas-automation` infrastructure profile:

```text
# /etc/sudoers.d/epas-automation

# Service Lifecycle Rules
enterprisedb ALL=(root) NOPASSWD: /bin/systemctl stop edb-as-15
enterprisedb ALL=(root) NOPASSWD: /bin/systemctl start edb-as-15
enterprisedb ALL=(root) NOPASSWD: /usr/bin/systemctl status edb-as-15

# Target File System Manipulation Rules
enterprisedb ALL=(root) NOPASSWD: /bin/mkdir -p /var/lib/edb/as15/data
enterprisedb ALL=(root) NOPASSWD: /bin/chown enterprisedb\:enterprisedb /var/lib/edb/as15/data
enterprisedb ALL=(root) NOPASSWD: /bin/chmod 700 /var/lib/edb/as15/data
enterprisedb ALL=(root) NOPASSWD: /bin/mv /var/lib/edb/as15/data /var/lib/edb/as15/data_bak_*

```