# Validation and Oracle lab checklist

The local environment has no Oracle database or SQL*Plus. The real Bash wrapper
is exercised on Linux using a fake SQL*Plus process. This tests input handling,
process failures, output/checksums, storage checks, attempted markers, resume
dispatch and local locking. It does not validate Oracle queries, PL/SQL
compilation, or actual redo lifecycle behavior.

```bash
for file in redoctl.sh tests/test_wrapper.sh examples/maintenance.sh; do bash -n "$file"; done
shellcheck redoctl.sh tests/test_wrapper.sh examples/maintenance.sh
bash tests/test_wrapper.sh
```

The included GitHub workflow runs those checks. ShellCheck is development tooling,
not a runtime dependency on the database host.

## First Oracle checks: no redo changes

Use a disposable single-instance Linux Oracle 19c+ database. Configure its real
DB_UNIQUE_NAME and set ORACLE_SID to the actual instance. SAP_SID can be a
three-character lab label controlling default paths. Connect to CDB root/non-CDB.

1. Run `analyze`. The complete anonymous PL/SQL block is compiled, even though
   DDL branches are not executed. Confirm no ORA/SP2/PLS errors.
2. Set `SIZE_MB` explicitly for a lab without history. Prepare two writable
   filesystem directories and run `plan`; verify that no redo DDL occurs.
3. Compare plan DBID/incarnation/thread/block size/originals/new paths with
   V$DATABASE, V$INSTANCE, V$LOG and V$LOGFILE.
4. No-data analysis must not invent a size. Automatic planning must fail;
   an explicit override must permit planning.
5. Test whole/day/night/custom windows, overnight custom windows, end-exclusive
   boundaries and equal endpoints (rejected).
6. Independently reconcile duplicate archive destinations and RMAN-deleted
   records. Changing copy counts must not change logical bytes; previous
   incarnations must be excluded.
7. Repeat with both `NLS_NUMERIC_CHARACTERS='.,'` and `',.'` in a test SQL*Plus
   login setup. Chosen sizes and numeric DDL must agree.

## Disposable database integration: changes redo configuration

Use no production database for these checks. Record the initial state and make
an appropriate lab recovery point. Never use sample PRD values on an unrelated DB.

- ADD-only: exactly the requested new groups and two correctly sized members;
  no forced switches or drops.
- Replacement: all additions before the first switch; every replacement used
  and healthy before the first original DROP; final count/members match the plan.
  Unmanaged old files must remain.
- No-op: matching size/directories/health/count results in no redo DDL.
- Failure of the second ADD: the first may remain, all originals must remain,
  and no SWITCH/DROP may run. Repair the cause and resume the same plan.
- Kill/disconnect after an ADD and after a DROP: inspect live inventory, then
  resume. Do not repeat completed DDL against different groups.
- Slow archiving/checkpoints: stop on wait/runtime bounds; never drop ACTIVE,
  CURRENT, UNUSED or unarchived originals.
- Insert an unexpected group, change an original member or collide with a
  planned ID between plan/apply: abort on drift.
- Apply two different plans concurrently: only one acquires the database lock;
  verify DDL commits do not release it.
- Wrong identity, changed incarnation, PDB, RAC, standby role and configured
  Data Guard: stop management before redo DDL.
- Existing destination file/symlink, missing directory, insufficient space and
  shared filesystems: abort before ADD when capacity/path checks fail.
- Force the outer SQL*Plus timeout: require nonzero exit and an attempted marker.
  Inspect the server-side session/lock before resuming uncertain DDL.

Record Oracle version/RU, SQL*Plus version, OS, storage type, logs and before/after
V$LOG/V$LOGFILE snapshots. Dynamic DDL syntax and actual filesystem behavior need
this real-database evidence before production use.
