# Redo Log Analysis and Management Script

## Purpose

This SQL*Plus script helps an Oracle DBA analyze archived redo generation and optionally manage online redo log groups.

It can:

- Calculate peak and average hourly redo generation from `V$ARCHIVED_LOG`.
- Recommend an individual redo log file size.
- Show current redo log groups from `V$LOG`.
- Suggest inactive and archived groups that may be candidates for dropping.
- Optionally drop existing redo log groups.
- Optionally add new redo log groups with two members.
- Optionally perform log switches after adding new groups.
- Optionally drop old groups after new groups have been added and switched into use.

## Requirements

- SQL*Plus or a compatible SQL client.
- DBA-level privileges.
- Access to Oracle dynamic performance views:
  - `V$ARCHIVED_LOG`
  - `V$LOG`
- Permission to run:
  - `ALTER DATABASE ADD LOGFILE`
  - `ALTER DATABASE DROP LOGFILE`
  - `ALTER SYSTEM SWITCH LOGFILE`
- The database should be in `ARCHIVELOG` mode for meaningful redo analysis.

## How To Run

If you extract the SQL from the Markdown file into a `.sql` file:

```bash
sqlplus / as sysdba @redo_log_analysis_and_management.sql
```

Or connect first, then run:

```sql
@redo_log_analysis_and_management.sql
```

## Script Flow

1. Enter the SAP SID.
2. Confirm or override the default redo log member paths:
   - `/oracle/<SID>/origlogA`
   - `/oracle/<SID>/mirrlogA`
3. Choose the redo analysis period:
   - 3 days
   - 5 days
   - 7 days
4. Choose the analysis time window:
   - Day
   - Night
   - Whole day
   - Custom
5. Review calculated peak and average redo generation.
6. Accept the recommended redo log size or enter a custom size.
7. Optionally drop existing inactive archived groups before adding new groups.
8. Enter new redo log group numbers.
9. Manually verify filesystem free space.
10. Confirm whether to add the new redo log groups.
11. Optionally perform log switches.
12. Optionally drop old groups after the new groups are active.
13. Review final guidance and check the database alert log.

## Safety Notes

- The script performs destructive DDL if confirmed.
- Default answers generally avoid dropping or adding redo log groups.
- Always review `V$LOG` before dropping any group.
- Only drop redo log groups that are `INACTIVE` and `ARCHIVED = YES`.
- Never drop the current redo log group.
- Confirm that every redo thread keeps enough groups after any drop.
- Check the alert log after every ADD, DROP, or SWITCH operation.
- Confirm free space on every filesystem before adding redo members.

Example filesystem checks:

```bash
df -h /oracle/<SID>/origlogA
df -h /oracle/<SID>/mirrlogA
```

## Output And Temporary Files

The script may create temporary SQL and listing files in the working directory, including:

- `__temp_customtime.sql`
- `__check_data_found.sql`
- `__temp_customsize.sql`
- `__add_skip_message.sql`
- `__temp_drop_prompt_pre.sql`
- `__temp_drop_prompt_post.sql`
- Corresponding `.lst` files, depending on SQL*Plus settings

These files can be deleted after the run.

## Important Review Points

Before using the original script in production, review these areas carefully:

- SQL*Plus error handling: validation errors raised in PL/SQL may not stop the full script unless SQL*Plus is configured to exit on SQL errors.
- `V$ARCHIVED_LOG` counting: multiple archive destinations can cause duplicate archived-log rows and inflated redo calculations.
- RAC/thread safety: group-count checks should be verified per thread.
- `REUSE` behavior: adding redo logs with `REUSE` can reuse existing files.
- Post-add flow: log switches and post-drop prompts should only be used after confirming the ADD operation succeeded.

## Recommended Operational Procedure

1. Run the script first for analysis only.
2. Save or spool the output.
3. Review redo generation, current log groups, and the recommended size.
4. Prepare exact ADD/DROP actions separately.
5. Check filesystem capacity.
6. Run ADD operations during an approved maintenance window.
7. Switch logs only after confirming new groups were added successfully.
8. Drop old groups only after they are inactive and archived.
9. Review the alert log and monitor log switching frequency.

