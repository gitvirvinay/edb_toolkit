# Postgres Database Request — Business Requirements Form

Version: 2026-11-09 · Owner: DBA team

> Working copy (edit and comment here first): https://claude.ai/artifact/1dt7B53oypfNo2CnVU83TY
> This file is the versioned copy. Update it here (and commit) whenever the form changes.

## How to use this form

The application team answers 12 business questions in Microsoft Forms (Part 1). The DBA team completes the detail with the developers at a 30-minute kickoff (Part 2) and turns it into the technical design (Part 3). No database knowledge is needed for Part 1.

- One form per application. It covers every environment the application needs (DEV, SIT, PAT, PROD, DR).
- Fields marked **(R)** are required before the DBA team starts. The others can follow, but late answers can delay the build.
- Write "Don't know" rather than guessing. The DBA team will help find the answer.
- Submit at least 6 weeks before the PROD date. Firewall rules, certificates and storage come from other teams and take time.
- Return the form to the DBA team with the change or request ticket number.

## Part 1 – Short form (Microsoft Forms build sheet)

The application team answers only these 12 questions, in Microsoft Forms. Everything else is settled in Part 2 at a 30-minute kickoff. Build it field by field from this table; "Follow-up" rows appear only for the answer shown (Forms: … menu → Add branching).

| # | Question text (as shown in Forms) | Forms type | Options | Required | Help text (Forms subtitle) |
| --- | --- | --- | --- | --- | --- |
| 1 | Application name and CMDB CI ID | Text | — | Yes | Example: Payroll Processing, CI0012345. Owner, cost centre and support group are taken from the CMDB |
| 2 | Business owner and technical contact | Text (long answer) | — | Yes | Business owner approves questions 5 and 7. Technical contact attends the kickoff |
| 3 | Which environments do you need? | Choice, multiple answers | DEV, SIT, PAT, PROD, DR | Yes | PAT is built like PROD, at smaller size |
| 4 | PROD go-live date | Date | — | Yes | Submit at least 6 weeks before this date |
| 5 | Availability class | Choice, one answer | Gold, Silver, Bronze, Basic, Don't know | Yes | Gold: 3 servers over 2 sites, automatic failover in ~1 min, no data loss on server failure. Silver: 2 servers, automatic failover in 1–5 min, seconds of data loss. Bronze: 2 servers, failover by DBA within 1 hour. Basic: 1 server, restore from backup in hours, up to 15 min data loss. Cost rises from Basic to Gold |
| 6 | When is the application used? | Choice, one answer | 24x7, Business hours only | Yes | — |
| 7 | Data classification | Choice, one answer | Public, Internal, Confidential, Restricted, Don't know | Yes | Don't know = treated as Confidential |
| 8 | Does it store personal data or payment card data? | Choice, one answer | Yes, No, Don't know | Yes | Personal data: names, addresses, ID numbers, health, salary |
| 8a | Follow-up if 8 = Yes: which kinds? | Text | — | Yes | Example: employee names and salaries |
| 9 | Data retention | Choice, one answer | Standard (35-day backups), Regulated | Yes | — |
| 9a | Follow-up if 9 = Regulated: which rule and how long? | Text | — | Yes | Example: financial records 7 years |
| 10 | New application or migration? | Choice, one answer | New, From Oracle, From SQL Server, From another Postgres, Other | Yes | — |
| 10a | Follow-up if migration: current database version and size | Text | — | No | Example: Oracle 19c, 800 GB |
| 11 | Is it a vendor product? | Choice, one answer | No (built in-house), Yes | Yes | — |
| 11a | Follow-up if 11 = Yes: product name and version | Text | — | Yes | The DBA team checks the vendor's supported databases |
| 12 | Expected database size and growth | Choice, one answer | S: under 100 GB, M: 100 GB–1 TB, L: over 1 TB, Don't know | Yes | Growth is discussed at the kickoff |

Forms settings:

- Create it as a **group form** owned by the DBA team's Microsoft 365 group, so it doesn't depend on one person's account.
- Settings: "Only people in my organization can respond", "Record name" on, "One response per person" off (one person may request several applications), email notification of each response on.
- Responses → "Open in Excel" gives one row per request. Copy the CI ID into the request ticket and book the kickoff.

## Part 2 – Kickoff worksheet (DBA fills in with the developers)

Sections A–G below are completed by the DBA during the 30-minute kickoff, using the Part 1 answers as a starting point. Questions already answered in Part 1 are only confirmed.

## Section A – Application and ownership

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| A1 | Application name **(R)** |  | Payroll Processing |
| A2 | Application code (APP code) **(R)** |  | PAYR. 2–6 letters, as in the CMDB. Used in the database name and server tags |
| A3 | CMDB / configuration item ID |  | CI0012345 |
| A4 | Business owner (name, department) **(R)** |  | Approves RPO/RTO and cost |
| A5 | Technical owner / application lead **(R)** |  | Main contact for the DBA team |
| A6 | Support team and escalation contact **(R)** |  | Team mailbox or on-call group |
| A7 | Cost centre |  |  |
| A8 | Short description: what the application does and who uses it |  | 2–3 sentences |
| A9 | New application, or migration from another database? **(R)** |  | New / from Oracle / from SQL Server / from another Postgres |
| A10 | If migration: current database product, version and size |  | Oracle 19c, 800 GB |
| A11 | Vendor product or built in-house? |  | If vendor: product name, version, and the vendor's supported database versions |

## Section B – Environments requested

Tick the environments you need and give the date each must be ready. PAT is built like PROD (same design, smaller size), so plan for it.

| Environment | Needed? (Y/N) **(R)** | Ready-by date **(R)** | Data centre / location | Notes |
| --- | --- | --- | --- | --- |
| DEV |  |  |  |  |
| SIT |  |  |  |  |
| PAT |  |  |  |  |
| PROD |  |  |  |  |
| DR (copy of PROD at a second site) |  |  |  | Needed if the business continuity plan names this application |

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| B1 | Planned go-live date for PROD **(R)** |  | A fixed date, or "not before" |
| B2 | Will PROD data be copied into DEV, SIT or PAT? **(R)** |  | If yes, the data must be masked first (Section D) |
| B3 | Expected life of the application |  | 5 years, permanent, temporary for a project |

## Section C – Availability and recovery (PROD)

These answers set the design and most of the cost, so the business owner must approve them. Two terms:

- **RPO (Recovery Point Objective):** how much recent data the business can afford to lose after a failure, measured in time.
- **RTO (Recovery Time Objective):** how long the application can be unavailable before it must be back.

Pick the class that fits. The DBA team will confirm the design and cost.

| Class | Data loss (RPO) | Downtime (RTO) | Typical design | Relative cost |
| --- | --- | --- | --- | --- |
| Gold | None | About 1 minute | Automatic failover, 2+ standby servers, DR site | Highest |
| Silver | Seconds | About 1–5 minutes | Automatic failover, 1 standby, DR optional | High |
| Bronze | Seconds to minutes | Under 1 hour | 1 standby, failover by the DBA on call | Medium |
| Basic | Up to 15 minutes | Several hours | Single server, restore from backup | Low |

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| C1 | Availability class (Gold / Silver / Bronze / Basic) **(R)** |  | Or give your own RPO and RTO |
| C2 | Maximum acceptable data loss (RPO) **(R)** |  | 0 / 1 minute / 15 minutes |
| C3 | Maximum acceptable downtime (RTO) **(R)** |  | 1 minute / 1 hour / 4 hours |
| C4 | Hours the application is used **(R)** |  | 24x7 / business hours Mon–Fri 07:00–19:00 ET |
| C5 | Business-critical periods with no changes allowed |  | Month-end, year-end, payroll run days |
| C6 | Preferred maintenance window for patching |  | Sunday 02:00–06:00 ET, monthly |
| C7 | Can the application handle a short reconnect (30–60 seconds) during a planned failover? |  | Yes / No / Don't know. Affects how patching is done |
| C8 | Is the application in the business continuity / DR plan? **(R)** |  | If yes, give the DR RTO and RPO |
| C9 | What happens to the business if the database is down for 4 hours? |  | Plain words: lost sales, regulatory breach, staff can't work |

## Section D – Data classification and compliance

The data's sensitivity decides encryption, auditing and who may access it. If unsure, ask your information security contact.

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| D1 | Data classification **(R)** |  | Public / Internal / Confidential / Restricted (use the company scheme) |
| D2 | Personal data (names, addresses, ID numbers, health, salary)? **(R)** |  | Yes / No. If yes, which kinds |
| D3 | Payment card data? **(R)** |  | Yes / No (PCI DSS) |
| D4 | Regulations that apply |  | PCI DSS, SOX, PIPEDA, GDPR, HIPAA, internal policy |
| D5 | How long must data be kept? |  | 7 years for financial records |
| D6 | Must old data be deleted or archived after that? |  | Yes: purge job owned by the application / No |
| D7 | How long must backups be kept? **(R)** |  | 35 days standard; longer only if a regulation requires it |
| D8 | Must every data access or change be audit-logged? |  | All changes / access to specific tables / logins only |
| D9 | If PROD data goes to non-PROD: who masks it, and how? |  | Required whenever B2 = Yes |
| D10 | Must data stay in a specific country or region? |  | Canada only |

## Section E – Workload and capacity

Estimates are fine; the DBA team sizes the servers from them and checks them with a load test in PAT.

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| E1 | Type of workload **(R)** |  | Many small transactions (online users) / reporting and analysis / batch jobs / mixed |
| E2 | Database size at go-live **(R)** |  | 50 GB |
| E3 | Expected growth per year **(R)** |  | 20 GB per year, or 30% per year |
| E4 | Number of application users (named / at the same time) |  | 2,000 named, 300 at peak |
| E5 | Peak load |  | 500 transactions per second, Monday 09:00 |
| E6 | Number of database connections the application opens |  | Ask the developers: connection pool size × number of app servers |
| E7 | Large batch jobs or data loads: when, and how big? |  | Nightly 01:00–03:00, loads 5 million rows |
| E8 | Reports run against the database? |  | If heavy, they may run on a read-only copy |
| E9 | Busiest periods of the year |  | Year-end, tax season |
| E10 | Response-time expectation for key screens or transactions |  | Under 1 second for login and search |

## Section F – Application connectivity and compatibility

The application developers or the vendor answer this section.

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| F1 | Language and database driver **(R)** |  | Java + JDBC 42.7, .NET + Npgsql, Python + psycopg |
| F2 | Does the application need Oracle compatibility (PL/SQL, Oracle functions, packages)? **(R)** |  | Yes / No. Yes means EDB Postgres Advanced Server |
| F3 | Database versions the application or vendor supports **(R)** |  | Postgres 15–17 |
| F4 | Extensions or special features needed |  | PostGIS, pg_cron, full-text search, partitioning |
| F5 | Where do the application servers run? **(R)** |  | Hostnames or subnets, data centre, cloud. Needed for firewall rules |
| F6 | Other systems that connect to the database |  | Reporting tool, ETL, interfaces to other apps |
| F7 | Does the application reconnect by itself after a failover? |  | Yes / No / Don't know. Needed for automatic failover |
| F8 | Can the application connect with encryption and certificate checking (TLS, verify-full)? |  | Required for Confidential data and above |
| F9 | Character set and language needs |  | French and English text, sorting rules |
| F10 | Time zone the application expects |  | UTC / America/Toronto |

## Section G – Access, support and operations

| # | Question | Answer | Example / guidance |
| --- | --- | --- | --- |
| G1 | Which people or teams need direct database access, and what kind? **(R)** |  | Developers: read-only in PROD, full in DEV. Support: read-only |
| G2 | AD / LDAP groups to use for that access |  | GRP-PAYR-DB-RO, GRP-PAYR-DB-RW |
| G3 | Application service account(s) needed |  | One read-write account for the app, one read-only for reporting |
| G4 | Support hours expected from the DBA team **(R)** |  | Business hours / 24x7 on call |
| G5 | Who must be told about outages and planned changes? |  | Mailbox or distribution list |
| G6 | Monitoring alerts the application team wants to receive |  | Database down, failover happened |
| G7 | Scheduled jobs that must run in the database |  | Nightly purge, statistics refresh |
| G8 | Approval needed for PROD changes |  | CAB ticket / app owner sign-off |
| G9 | Who signs off a restore test and a failover test before go-live? |  | Usually the technical owner (A5) |

## Part 3 – How the answers drive the build (DBA team use)

The application team can skip this section. It shows the DBA team which answers set which technical decisions, and later feeds `site.env` in the toolkit.

| Answer | Decides | Rule of thumb |
| --- | --- | --- |
| A2 APP code + Section B tier | `cluster_name`, `dba.app_code`, `dba.env_tag`, server and DNS names | `cluster_name = <APP>_<ENV>_<asNN>` |
| C1–C3 class, RPO, RTO | Topology: standalone, standby, automatic failover (EFM), DR | Gold/Silver = EFM + witness; Bronze = standby with manual failover; Basic = single server |
| C2 RPO = 0 | Synchronous replication | Needs 2 standbys (`ANY 1`) so one failure doesn't stop writes |
| C4–C7 hours, windows, reconnect | Patching method and schedule | Reconnect OK = rolling patch with switchover; otherwise full outage window |
| C8 DR = yes | DR standby at second site, DR runbook and tests | DR is usually promoted manually |
| D1–D3 classification, personal or card data | TDE, `verify-full` SSL, audit logging, access reviews | Confidential and above: all of them |
| D5–D7 retention | Backup retention, archive or purge plan | Backup retention is set in pgBackRest/Barman, never by delete scripts |
| D9 masking | Non-PROD refresh process | No unmasked PROD data outside PROD |
| E1–E5 workload, size, growth, peak | CPU, RAM, disk sizes, `shared_buffers`, WAL sizing | Size for 3 years of growth; load test in PAT |
| E6 connections | `max_connections`, connection pooler (pgBouncer) | More than ~300 connections: add a pooler |
| E8 heavy reports | Read-only replica | Keeps reports off the primary |
| F2 Oracle compatibility | EPAS with redwood mode, or community Postgres | Fixed at `initdb`; can't change later |
| F3–F4 versions, extensions | Version choice, `shared_preload_libraries` | Pick the newest version the vendor supports |
| F5–F6 app servers, other systems | Firewall rules, `pg_hba.conf` subnets | Request on day 1 |
| F7 auto-reconnect = no | Failover design is weakened | Fix in the app, or accept a longer RTO |
| F9–F10 language, time zone | Encoding, locale, collation at `initdb` | UTF8 always; fixed at `initdb` |
| G1–G3 access | Roles, AD groups, service accounts, SailPoint feeds | No superuser for apps or people's daily work |
| G4–G6 support, alerts | Monitoring and alert routing | Gold/Silver need 24x7 paging |

## Review and sign-off

The build starts only after the business owner has approved Section C (availability) and Section D (data), because those two sections set the design and the cost.

| Role | Name | Date | Signature / ticket |
| --- | --- | --- | --- |
| Business owner (A4) |  |  |  |
| Technical owner (A5) |  |  |  |
| Information security (if D1 is Confidential or Restricted) |  |  |  |
| DBA team lead |  |  |  |

- [ ] Required (R) fields complete
- [ ] Availability class and RPO/RTO approved by the business owner
- [ ] Data classification confirmed
- [ ] Request ticket number recorded
