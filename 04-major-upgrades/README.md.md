```markdown
# EDB Postgres Advanced Server (EPAS) Major Upgrade Utility

A unified, automated Bash script for performing major version upgrades of **EDB Postgres Advanced Server (EPAS)** using `pg_upgrade`. It supports both **Copy Mode** and **Link Mode**, automatically handles **Transparent Data Encryption (TDE)** key wrapping, and can accept environment-specific parameters via an external configuration file (`deploy.env`)[cite: 1, 2, 3, 4].

---

## Features

- **Unified Execution Workflow:** Combines Copy Mode and fast Link Mode (`--link`) upgrades into a single script[cite: 1, 2].
- **Dynamic Configuration:** Loads operational parameters dynamically from `.env` files (e.g., `deploy.env`)[cite: 4].
- **TDE Key Management:** Handles TDE passphrase prompts securely or inherits predefined `TDE_WRAP_CMD` / `TDE_UNWRAP_CMD` definitions[cite: 1, 4].
- **Preflight & Safety Checks:** Enforces pre-upgrade filesystem backup confirmations, disk space validation, and structural compatibility preflight analysis (`--check`) before making permanent alterations[cite: 1, 3].
- **Service Control:** Automatically handles stopping old database services and starting new services using Systemd (`systemctl`)[cite: 1].
- **Post-Upgrade Optimization:** Runs post-upgrade statistics generation (`analyze_new_cluster.sh`) upon completion[cite: 1].

---

## Directory & File Requirements

Before running the script, ensure the following directory structure and configuration files are in place:

```text
.
├── epas-major-pgupgrade-unified.sh   # Main upgrade script
├── deploy.env                        # (Optional) Deployment environment configuration
├── analyze_new_cluster.sh            # (Optional) Post-upgrade stats generation script
└── config/
    └── logger.sh                     # Logging helper script

```

---

## Deployment Environment Configuration (`deploy.env`)

You can supply deployment settings via `--env deploy.env`. Below is an example structure supported by the script:

```bash
# EPAS Version & Directories
EPAS_VERSION=17
SERVICE_NAME=edb-as-17
SYSTEM_USER=enterprisedb
SYSTEM_GROUP=enterprisedb
SRC_BINARY_DIR=/usr/edb/as17
DATA_TOP=/u001/data/as17

# Network / Cluster Config
PRIMARY_PORT=5444
PRIMARY_HOST="192.168.1.11"

# TDE Configuration (Optional)
TDE_WRAP_CMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass pass:YOUR_PASSPHRASE -out %p"
TDE_UNWRAP_CMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass pass:YOUR_PASSPHRASE -in %p"
```[cite: 4]

---

## Command Line Usage

### Syntax

```bash
./epas-major-pgupgrade-unified.sh [--env <path_to_env>] [--link] [--root]

```

### Options

| Flag | Description |
| --- | --- |
| `--env <file>` | Path to an environment file (e.g., `deploy.env`) containing cluster paths, service names, and TDE rules.

 |
| `--link` | Enables **Link Mode** (`pg_upgrade --link`). Uses hardlinks instead of copying data files. Significantly faster for large databases.

 |
| `--root` | Explicitly permits script execution as `root` (EUID 0). Upgrades execute commands via `sudo -u <SYSTEM_USER>`.

 |
| `-h, --help` | Displays usage instructions and exits. |

---

## Usage Examples

### 1. Standard Copy Upgrade (Interactive Prompting)

Runs as the default `enterprisedb` user. Prompts interactively for TDE passphrase and backup confirmation.

```bash
./epas-major-pgupgrade-unified.sh

```

### 2. Standard Upgrade using `deploy.env`

Loads directory paths, service names, and TDE environment parameters directly from `deploy.env`:

```bash
./epas-major-pgupgrade-unified.sh --env deploy.env

```

### 3. Fast Link-Mode Upgrade as `root`

Recommended for large production databases requiring minimal downtime. Executed as `root` to simplify Systemd service management and cross-directory privilege permissions:

```bash
sudo ./epas-major-pgupgrade-unified.sh --env deploy.env --link --root

```

---

## Upgrade Steps Executed

1. **Parameter & Context Validation:** Verifies running user permissions, command line arguments, and optional environment file contents.


2. **Disk Space Verification:** (Copy Mode only) Calculates source directory size and ensures destination partition has at least 110% available space.


3. **Backup & TDE Verification:** Confirms filesystem backup and sets up TDE environment key wrap commands.


4. **Preflight Structural Analysis:** Executes `pg_upgrade --check` to verify compatibility between old and new clusters without making changes.


5. **Service Shutdown:** Stops `edb-as-14` and `edb-as-17` services via Systemd.


6. **Data Migration:** Executes `pg_upgrade` in either Copy or Link mode.


7. **Service Startup & Optimization:** Starts the new `edb-as-17` service and executes `analyze_new_cluster.sh` to rebuild optimizer statistics.



---

## Troubleshooting & Safety Notes

* **Backup Safety:** Always take a full, verified filesystem-level cold backup before running `pg_upgrade` (especially in `--link` mode).


* **Link Mode Reversion:** Once an upgrade is run in `--link` mode, the old cluster data directory cannot be started again because hardlinks are modified in place.


* **Temporary Logs:** The script automatically switches context to `/tmp` during execution to ensure `pg_upgrade` log files can be created without permission errors.



```

```