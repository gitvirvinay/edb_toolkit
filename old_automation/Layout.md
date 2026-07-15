# Enterprise EPAS Automation Workspace Layout

This document details the directory architecture and organizational standards for the `/u001/automation/` git workspace root. The workspace isolates operational tasks into domain-driven modules to ensure high scalability, reusability, and seamless code maintenance.

## Workspace Tree

```text
/u001/automation/ (or your git workspace root)
├── Layout.md                           # This file (Repository structural blueprint)
├── README.md                           # Global repository setup and playbook introduction
│
├── epas_build/                         # Day 1: Provisioning & Instance Cloning
│   ├── README.md
│   ├── epas-base-build.sh
│   └── epas-clone.sh
│
├── epas_configure/                     # Cluster Tuning & Infrastructure Hardening
│   ├── README.md
│   ├── configure-memory.sh
│   ├── configure-systemd.sh
│   ├── configure-network.sh
│   └── configure-ssl.sh
│
├── epas_patch/                         # Day 2: In-place Minor Engine Updates
│   ├── README.md
│   └── epas-minor-patch.sh
│
├── epas_upgrade/                       # Major Version Transformations (e.g., 14 -> 17)
│   ├── README.md
│   ├── epas-major-pgupgrade.sh
│   └── epas-major-pgrestore.sh
│
├── backup/                             # Physical & Logical Disaster Recovery Routines
│   ├── README.md
│   ├── backup.sh
│   └── restore.sh
│
├── health/                             # Cluster Validation & Active Observability
│   ├── README.md
│   ├── health-check.sh
│   └── validate-install.sh
│
├── lib/                                # Shared Script Utilities & Core Functions
│   ├── README.md
│   └── common.sh
│
├── templates/                          # Static & Dynamic Configuration Blueprints
│   ├── README.md
│   ├── postgresql.conf.template
│   ├── pg_hba.conf.template
│   └── tde-systemd.conf.template
│
└── tests/                              # Automated Pipeline Validation & Testing
    ├── README.md
    └── run-pipeline-tests.sh