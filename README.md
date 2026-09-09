# SAP Oracle Redo Log Analysis and Automation

Analyze archived redo generation, recommend a redo member size, and optionally
add or replace online redo groups with two members. The automation version runs
on **SUSE Linux Enterprise Server 15 SP5+ using Bash and SQL*Plus**. It needs no
Python, project-specific database installation, or interactive answers.

The original intent is preserved:

- SAP SID defaults `/oracle/<SID>/origlogA` and `/oracle/<SID>/mirrlogA`.
- Analysis of 3, 5, or 7 days, with day, night, whole-day, or custom windows.
- Peak/average archived-redo estimates and an explicit size override.
- Automatic group-number suggestions or an explicit list.
- Two members per new group, storage checks, and optional replacement of old groups.

Replacement follows **ADD all replacements → verify → switch and wait → DROP
original groups → verify final configuration**. It never drops groups to make
room before their replacements exist.

**Validation status:** Bash failure-path tests have run on Linux. Oracle
compilation and ADD/SWITCH/DROP integration still need an Oracle lab. This is not
a production-validated release. See [testing](docs/TESTING.md).

## Supported target

- Single-instance Oracle **19c or newer**, on the database host.
- PRIMARY, READ WRITE, ARCHIVELOG; CDB root or non-CDB.
- Filesystem destinations, with the existing redo block size preserved.
- Run as the Oracle software owner with `ORACLE_HOME` and `ORACLE_SID` set.
- Local OS authentication through `sqlplus -L -S '/ as sysdba'`; no passwords
  appear in configuration or command arguments.

Management stops if RAC, other redo threads, a configured standby archive
destination, or standby redo groups are detected. Data Guard and ASM creation
need dedicated handling and are outside this version's management scope.
`analyze` reports the connected instance's thread only.

Required OS utilities are GNU core utilities, Bash 4.4+, `awk`, `grep`, `sed`,
`hostname`, and `flock` from util-linux. Install the tool in a path without spaces
or shell/SQL*Plus metacharacters, for example `/opt/ora-redo-mgmt`. Use SQL*Plus
from the same Oracle home as the database.

## Quick start

Copy this repository to the database host. Restrict write access to the Oracle
owner, then prepare a configuration:

```bash
cd /opt/ora-redo-mgmt
chmod +x redoctl.sh
cp examples/sap-redo.conf sap-redo.conf
```

Edit at least `SAP_SID` and `DB_UNIQUE_NAME`. The SID controls default paths;
`DB_UNIQUE_NAME` independently verifies the connected database. Configuration is
literal `KEY=value`, without quotes, variable expansion, or inline comments.
Do **not** `source` it.

The Oracle owner's environment must set the real home and instance, for example:

```bash
export ORACLE_HOME=/oracle/PRD/19
export ORACLE_SID=PRD
```

Analyze without changing the database:

```bash
./redoctl.sh analyze --config sap-redo.conf --output /oracle/PRD/redo-analysis-001
```

Generate a plan without changing the database:

```bash
./redoctl.sh plan --config sap-redo.conf --output /oracle/PRD/redo-plan-001
```

The output directory must not already exist. Review `plan.log` and `plan.json`.
The plan fixes the size, group IDs, filenames, DB identity, incarnation and
original group structure. Editing configuration afterward does not change it.
`plan.sha256` detects accidental edits; it is not a digital signature.

Apply that exact plan without prompts:

```bash
./redoctl.sh apply --plan /oracle/PRD/redo-plan-001
```

Only `apply` changes redo configuration. `OPERATION=add` adds and verifies groups
without switching or dropping. `OPERATION=replace` activates the replacement set
and retires the original groups.

For an approved unattended maintenance job, invoke `plan` followed by `apply`
and stop on either command's nonzero exit. See [examples/maintenance.sh](examples/maintenance.sh).
Schedule analysis routinely; use replacement for deliberate maintenance. A
changing measured peak can produce a different size on successive days. Use an
explicit `SIZE_MB` when a fixed desired size is needed.

## Configuration

Start with [examples/sap-redo.conf](examples/sap-redo.conf). Defaults:

| Setting | Meaning |
| --- | --- |
| `DAYS=3` | 3, 5, or 7 days ending at the last complete database-clock hour |
| `WINDOW=whole` | `whole`, `day` (08:00–18:00), `night` (18:00–08:00), or `custom` |
| `START_TIME` / `END_TIME` | Custom HH24:MI, start inclusive and end exclusive; end can be `24:00` |
| `TARGET_SWITCH_MINUTES=60` | Nominal capacity interval before headroom |
| `HEADROOM_PERCENT=150` | Preserves the original hourly peak × 1.5 intent with the 60-minute target |
| `MIN_SIZE_MB=100` | Lower bound in MiB, at least 4 |
| `MAX_SIZE_MB=8192` | Policy ceiling; exceeding it stops planning instead of silently capping |
| `SIZE_MB=0` | Automatic sizing; positive integer is an override within the configured bounds |
| `OPERATION=replace` | `replace` or `add` |
| `TARGET_GROUP_COUNT=0` | Replace: preserve current count, default minimum 3; explicit count 2–32. Add: number to add, 1–32 |
| `NEW_GROUPS=` | Empty allocates IDs above existing online/standby groups; otherwise a distinct, unused CSV list matching the count to create |
| `RESERVE_MB=1024` | Free-space reserve per filesystem after all required new members |
| `WAIT_SECONDS=600` | Polling limit for activation, archiving and checkpoints |
| `POLL_SECONDS=5` | Interval between checks and optional switches |
| `MAX_SWITCHES=32` | Per-invocation switch limit; an explicit resume gets a new bounded attempt |
| `MAX_RUNTIME_SECONDS=1800` | Whole SQL*Plus timeout per phase; must exceed WAIT_SECONDS |
| `PLAN_MAX_AGE_HOURS=24` | Fresh-apply limit; an already-started plan may resume later if live replacement identities match |

Sizing uses unrounded numbers:

```text
ceil(estimated_peak_MiB_per_hour × target_minutes / 60 × headroom_percent / 100)
```

The minimum is then applied. No data yields **no automatic recommendation**.
An explicit `SIZE_MB` permits a deliberate plan without history. New groups use
new IDs; never specify an old ID for reuse in the same plan.

If size, both member directories, member health and final count already match,
a replacement plan is a no-op. Explicit `NEW_GROUPS` requests replacement even
when those attributes match.

## Analysis limits

The query counts each archived log once by incarnation, thread and sequence,
including metadata for archives subsequently deleted by RMAN. Physical file
availability is not a measure of historical generation.

Each log's bytes are attributed to its `FIRST_TIME` hour. This is an **estimate**,
not a measured hourly redo counter. Logs spanning hours, incomplete history and
unarchived redo affect it. Empty selected buckets count as zero in the average;
observed hours, earliest/latest log starts, duplicate counts and logs spanning
more than an hour are reported separately. Empty buckets cannot distinguish idle
time from missing control-file records.

Custom windows are half-open to avoid overlap. Partial-hour buckets are normalized
by their selected fraction of an hour. Windows use the database clock, not the
client timezone.

## Execution and recovery

- Preflight verifies the plan and emits required new file paths and sizes.
- Bash checks the actual host filesystems and combines allocations when both
  directories share a device ID. Existing destination files/symlinks are rejected.
  `REUSE` is never emitted.
- Names such as `log_g4m1_<plan-id>.dbf` distinguish a plan's replacements from
  another operation's files, including during recovery.
- `DBMS_LOCK` serializes cooperating runs across DDL commits; `flock` protects
  the plan directory. Other DBA tools do not honor this lock: coordinate concurrent
  maintenance.
- Every addition must match the planned members, size, thread and block size
  before switching. Every replacement must have been used and have healthy
  members before any original group is dropped.
- DROP is restricted to recorded originals, freshly verified as `INACTIVE` and
  `ARCHIVED=YES`, while retaining the planned count and at least two groups in
  the thread.
- SQL, OS and SQL*Plus errors fail the command. Completion requires a phase-specific
  success marker and final inventory checks.
- Unmanaged old files remain on disk. Logs identify their paths for separate
  verified cleanup. Oracle-managed originals may be removed by Oracle itself.
  The tool never runs filesystem deletion commands.
- DDL commits independently. Timeout/disconnect can leave completed changes;
  killing SQL*Plus does not prove server-side DDL was cancelled. Inspect the live
  database and log, then resume the **same plan**:

```bash
./redoctl.sh apply --plan /oracle/PRD/redo-plan-001 --resume
```

Resume reconciles live group structures and unique filenames. Unexpected groups,
ID collisions, changed originals, or missing originals without a complete usable
replacement set stop execution. If a failed ADD leaves an orphan file, resume
refuses that collision; investigate it manually. Do not create a new replacement
plan over an unresolved partial run.

SQL*Plus buffers `DBMS_OUTPUT` until the PL/SQL call finishes, so logs are not a
durable statement-by-statement journal during a disconnect. Keep the plan directory
as the recovery reference. Every invocation retains its own logs and generated
bind-input driver in a private directory.

Capacity checks cannot reserve space against other processes or fully account
for thin provisioning, quotas or storage pools. Distinct paths do not prove
independent physical failure domains; retain normal storage-level checks.

## Tests and references

```bash
for file in redoctl.sh tests/test_wrapper.sh examples/maintenance.sh; do bash -n "$file"; done
shellcheck redoctl.sh tests/test_wrapper.sh examples/maintenance.sh
bash tests/test_wrapper.sh
```

These checks need no Oracle. [docs/TESTING.md](docs/TESTING.md) lists the remaining
Oracle lab checks. The GitHub workflow runs Bash checks only.

Primary references:

- [V$ARCHIVED_LOG](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-ARCHIVED_LOG.html)
- [Redo group restrictions](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ALTER-DATABASE.html)
- [Switch/checkpoint behavior](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/ALTER-SYSTEM.html)
- [File specification and REUSE](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/file_specification.html)
- [SQL*Plus error handling](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqpug/WHENEVER-SQLERROR.html)
- [Locks surviving commits](https://docs.oracle.com/en/database/oracle/oracle-database/19/arpls/DBMS_LOCK.html)
- [PL/SQL JSON types](https://docs.oracle.com/en/database/oracle/oracle-database/19/adjsn/using-PLSQL-object-types-for-JSON.html)

The historical [interactive script](redo_log_analysis_and_management.sql) is
retained for reference. It has the safety issues identified in the review;
use `redoctl.sh` for the new automation workflow.
