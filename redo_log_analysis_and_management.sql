SET ECHO OFF
REM SQL*Plus Environment Settings
SET VERIFY OFF
SET FEEDBACK OFF
SET PAGESIZE 200 
SET LINESIZE 180
SET HEADING ON
CLEAR SCREEN
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON 

----------------------------------------------------------------------------------
-- Author: Naxterra
--
-- Script Name: Oracle Redo Log Advisor and Management Helper
--
-- Purpose: This script analyzes archived redo log generation to recommend
--          appropriate redo log file sizes. It can optionally assist with
--          managing redo log groups by dropping old/unused ones and adding
--          new ones based on user confirmation and inputs.
--          It includes safety checks and prompts for manual filesystem
--          space verification before performing DDL operations.
----------------------------------------------------------------------------------

-- Title Handling
SET DEFINE OFF
PROMPT
PROMPT =========================================================================
PROMPT Oracle Redo Log Advisor and Management Helper (Interactive)
PROMPT =========================================================================
PROMPT
PROMPT This script analyzes redo generation, recommends sizes (max 8GB), and can
PROMPT optionally help manage redo log groups. It includes prompts for manual
PROMPT filesystem space checks before DDL operations.
PROMPT New redo logs will be named using log_g<group>m<member>.dbf convention.
PROMPT Peak/average redo calculations are automated.
PROMPT You can override the recommended log size.
PROMPT Script will suggest next available group numbers for ADD.
PROMPT Script will halt on invalid YES/NO input for critical confirmations.
PROMPT
PROMPT !!! WARNING: Executing DDL (ADD/DROP LOGFILE) carries risk. !!!
PROMPT !!! Ensure you have backups and understand the actions.       !!!
PROMPT
SET DEFINE ON

-- Section 1: Get SAP SID and Determine Default Log Paths
PROMPT
PROMPT =========================================================================
PROMPT Section 1: System Identification and Log Paths
PROMPT =========================================================================
PROMPT
ACCEPT ora_sid_input CHAR PROMPT 'Enter SAP SID (will be uppercased): '
COLUMN ora_sid_col NEW_VALUE sid_val_internal NOPRINT
SELECT UPPER(TRIM('&ora_sid_input')) AS ora_sid_col FROM DUAL;

COLUMN default_dir1_col NEW_VALUE default_log_path1_val NOPRINT
COLUMN default_dir2_col NEW_VALUE default_log_path2_val NOPRINT
SELECT TRIM('/oracle/&&sid_val_internal/origlogA') AS default_dir1_col, 
       TRIM('/oracle/&&sid_val_internal/mirrlogA') AS default_dir2_col 
FROM DUAL;

PROMPT
PROMPT Default log directories for SID "&&sid_val_internal":
PROMPT Member 1: &&default_log_path1_val
PROMPT Member 2: &&default_log_path2_val
PROMPT (These are OFA-style defaults. Enter your specific paths if different,
PROMPT  e.g., /oracle/log_dir1, /oracle/log_dir2, or even the same path for both members.)
PROMPT

ACCEPT log_path1 CHAR DEFAULT '&&default_log_path1_val' PROMPT 'Path for member 1 files ["&&default_log_path1_val"]: '
ACCEPT log_path2 CHAR DEFAULT '&&default_log_path2_val' PROMPT 'Path for member 2 files ["&&default_log_path2_val"]: '
PROMPT

-- Section 2: Days for Analysis
PROMPT
PROMPT =========================================================================
PROMPT Section 2: Analysis Period
PROMPT =========================================================================
PROMPT
PROMPT How many days for redo log analysis?
PROMPT 1) 3 days
PROMPT 2) 5 days
PROMPT 3) 7 days
ACCEPT days_option CHAR PROMPT 'Choose [1-3] (default 1): ' DEFAULT '1'

COLUMN selected_days_col NEW_VALUE days_var_val NOPRINT
SELECT TRIM(TO_CHAR(
    CASE TRIM('&days_option')
        WHEN '1' THEN 3
        WHEN '2' THEN 5
        WHEN '3' THEN 7
        ELSE 3 
    END)) AS selected_days_col
FROM DUAL;
PROMPT Using analysis period of &&days_var_val days.
PROMPT

-- Section 3: Time Window for Analysis
PROMPT
PROMPT =========================================================================
PROMPT Section 3: Analysis Time Window
PROMPT =========================================================================
PROMPT
PROMPT Choose time window for analysis:
PROMPT 1) 08:00-18:00 (Day)
PROMPT 2) 18:00-08:00 (Night)
PROMPT 3) 00:00-23:59 (Whole Day)
PROMPT 4) Custom
ACCEPT time_window_option CHAR PROMPT 'Choose [1-4] (default 3): ' DEFAULT '3'

DEFINE p_custom_tstart = '00:00'
DEFINE p_custom_tend   = '23:59'

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __temp_customtime.sql REPLACE
SELECT
  CASE TRIM('&time_window_option')
    WHEN '4' THEN
      'PROMPT Custom time window selected (option 4):' || CHR(10) ||
      'ACCEPT p_custom_tstart CHAR DEFAULT ''00:00'' PROMPT ''Custom START (HH24:MI): ''' || CHR(10) ||
      'ACCEPT p_custom_tend CHAR DEFAULT ''23:59'' PROMPT ''Custom END (HH24:MI): '''
    ELSE
      'REM Using predefined time window (Opt &time_window_option).'
  END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF 
SET PAGESIZE 200 
@__temp_customtime.sql

COLUMN final_tstart_col NEW_VALUE tstart_var_val NOPRINT
COLUMN final_tend_col NEW_VALUE tend_var_val NOPRINT

SELECT
    TRIM(CASE TRIM('&time_window_option')
        WHEN '1' THEN '08:00'
        WHEN '2' THEN '18:00'
        WHEN '3' THEN '00:00'
        WHEN '4' THEN TRIM('&p_custom_tstart')
        ELSE '00:00'
    END) AS final_tstart_col,
    TRIM(CASE TRIM('&time_window_option')
        WHEN '1' THEN '18:00'
        WHEN '2' THEN '08:00'
        WHEN '3' THEN '23:59'
        WHEN '4' THEN TRIM('&p_custom_tend')
        ELSE '23:59'
    END) AS final_tend_col
FROM DUAL;
PROMPT Using time window: &&tstart_var_val to &&tend_var_val
PROMPT

-- Section 4: Automated Peak and Average Redo Calculation
PROMPT
PROMPT =========================================================================
PROMPT Section 4: Analyzing Archived Redo Log Data (Automated Calculation)
PROMPT =========================================================================
PROMPT
PROMPT Calculating peak/avg hourly redo for last &&days_var_val days (Time: &&tstart_var_val-&&tend_var_val)...
PROMPT (This may take a few moments)
PROMPT

COLUMN peak_mb_calc_col NEW_VALUE peak_mb_calculated NOPRINT
COLUMN avg_mb_calc_col NEW_VALUE avg_mb_calculated NOPRINT
COLUMN total_hours_sampled_col NEW_VALUE total_hours_sampled NOPRINT
COLUMN data_found_flag_col NEW_VALUE data_found_flag NOPRINT

SELECT
    TRIM(TO_CHAR(NVL(MAX(hourly_summary.mb_generated), 0))) AS peak_mb_calc_col,
    TRIM(TO_CHAR(ROUND(NVL(AVG(hourly_summary.mb_generated), 0), 1))) AS avg_mb_calc_col, 
    TRIM(TO_CHAR(COUNT(hourly_summary.mb_generated))) AS total_hours_sampled_col,
    CASE WHEN COUNT(hourly_summary.mb_generated) > 0 THEN 'YES' ELSE 'NO' END as data_found_flag_col
FROM (
    SELECT
        ROUND(SUM(CAST(a.BLOCKS AS NUMBER) * CAST(a.BLOCK_SIZE AS NUMBER)) / 1024 / 1024, 1) AS mb_generated
    FROM
        V$ARCHIVED_LOG a
    WHERE
        a.FIRST_TIME >= (SYSDATE - &&days_var_val)
        AND a.NAME IS NOT NULL
        AND a.STATUS = 'A'
        AND (
            ('&&tstart_var_val' < '&&tend_var_val' AND TO_CHAR(a.FIRST_TIME, 'HH24:MI') BETWEEN '&&tstart_var_val' AND '&&tend_var_val')
            OR
            ('&&tstart_var_val' > '&&tend_var_val' AND
                (TO_CHAR(a.FIRST_TIME, 'HH24:MI') >= '&&tstart_var_val' OR TO_CHAR(a.FIRST_TIME, 'HH24:MI') <= '&&tend_var_val')
            )
        )
    GROUP BY
        TO_CHAR(a.FIRST_TIME, 'YYYY-MM-DD HH24')
) hourly_summary;
REM Values from analysis captured. Peak='&&peak_mb_calculated'. Found='&&data_found_flag'.

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __check_data_found.sql REPLACE
SELECT
  CASE TRIM('&&data_found_flag')
    WHEN 'NO' THEN
      'PROMPT WARNING: No archived redo data found for the period.' || CHR(10) ||
      'PROMPT          Calculated Peak/Average will be 0. Recommendations may be inaccurate.'
    ELSE
      'PROMPT Data analysis complete.' || CHR(10) ||
      'PROMPT   Peak hourly redo calculated: &&peak_mb_calculated MB' || CHR(10) ||
      'PROMPT     (CRITICAL: Evaluate if this peak is representative of normal, sustained peak operations,' || CHR(10) ||
      'PROMPT      not a rare anomaly. Recommendation is based on THIS peak.)' || CHR(10) ||
      'PROMPT   Average hourly redo calculated: &&avg_mb_calculated MB (over &&total_hours_sampled sampled hours).'
  END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF 
SET PAGESIZE 200 
@__check_data_found.sql
PROMPT

-- Section 5: Calculate Recommended Redo Log Size & User Override
SET DEFINE OFF
PROMPT
PROMPT =========================================================================
PROMPT Section 5: Calculate Recommended Redo Log Size and User Confirmation
PROMPT =========================================================================
PROMPT
SET DEFINE ON
PROMPT Calculating script recommendation for redo log file size...

DEFINE min_log_size_mb = 100
DEFINE max_rec_log_size_mb = 8192 

DEFINE final_script_rec_mb_val = '' 
COLUMN temp_final_rec_col NEW_VALUE final_script_rec_mb_val NOPRINT
SELECT
    TRIM(TO_CHAR(GREATEST(
        LEAST(
            CEIL(NVL(TO_NUMBER(REPLACE('&&peak_mb_calculated', ',', '.')), 0) * 1.5),
            TO_NUMBER('&max_rec_log_size_mb')
        ),
        TO_NUMBER('&min_log_size_mb')
    ))) AS temp_final_rec_col
FROM DUAL;
REM Script recommended size '&&final_script_rec_mb_val' MB captured.

PROMPT
PROMPT Script Recommended individual redo log file size: &&final_script_rec_mb_val MB.
PROMPT (Based on Peak * 1.5 (max &max_rec_log_size_mb.MB), adjusted to min &min_log_size_mb.MB).
PROMPT

ACCEPT confirm_rec_size_input CHAR DEFAULT 'YES' PROMPT 'Use size &&final_script_rec_mb_val.MB? (Enter YES to use; NO for custom size) [YES]: '

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_rec_size_input'));
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y', 'NO', 'N') THEN
    DBMS_OUTPUT.PUT_LINE('!!! ERROR: Invalid input "&&confirm_rec_size_input" received. Expected YES or NO. !!!');
    DBMS_OUTPUT.PUT_LINE('!!! Halting script to prevent unintended actions. Please re-run with valid input. !!!');
    RAISE_APPLICATION_ERROR(-20001, 'Invalid input for recommendation confirmation.');
  END IF;
END;
/

DEFINE ddl_log_size_mb = '' 
DEFINE entered_custom_size_val = '' 

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __temp_customsize.sql REPLACE
SELECT
  CASE 
    WHEN UPPER(TRIM('&confirm_rec_size_input')) IN ('NO', 'N') THEN
      'PROMPT You chose to enter a custom size.' || CHR(10) ||
      'ACCEPT entered_custom_size_val NUMBER DEFAULT &&final_script_rec_mb_val PROMPT ''Enter desired log file size in MB (e.g., 512): '''
    ELSE
      'REM Using script recommended size of &&final_script_rec_mb_val.MB for new logs.' || CHR(10) ||
      'DEFINE entered_custom_size_val = &&final_script_rec_mb_val' 
  END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF
SET PAGESIZE 200
@__temp_customsize.sql

COLUMN temp_ddl_size_col NEW_VALUE ddl_log_size_mb NOPRINT
SELECT
  CASE 
    WHEN UPPER(TRIM('&confirm_rec_size_input')) IN ('NO', 'N') THEN
      TRIM(TO_CHAR(REPLACE(TRIM('&entered_custom_size_val'), ',', '.'))) 
    ELSE
      TRIM(TO_CHAR(REPLACE(TRIM('&&final_script_rec_mb_val'), ',', '.')))
  END AS temp_ddl_size_col
FROM DUAL;
REM Final DDL log size chosen: &&ddl_log_size_mb.MB.
PROMPT

-- Section 6: Optional - Drop Existing Log Groups
PROMPT
PROMPT =========================================================================
PROMPT Section 6: Optional - Drop Existing Log Groups BEFORE Adding New Ones
PROMPT =========================================================================
PROMPT
PROMPT Current Redo Log Groups (from V$LOG):
SET HEADING ON
SELECT GROUP#, THREAD#, SEQUENCE#, BYTES/1024/1024 AS SIZE_MB, MEMBERS, STATUS, ARCHIVED FROM V$LOG ORDER BY GROUP#;
SET HEADING OFF
PROMPT
PROMPT Identifying potential groups to drop (INACTIVE, ARCHIVED, not violating min 2/thread rule)...
DECLARE
  CURSOR c_droppable_groups IS
    SELECT group#, thread#
    FROM v$log l
    WHERE STATUS = 'INACTIVE'
      AND ARCHIVED = 'YES'
      AND (SELECT COUNT(*) FROM v$log WHERE thread# = l.thread# AND group# != l.group#) >= 2 
    ORDER BY group#;
  l_droppable_list VARCHAR2(1000);
  l_count PLS_INTEGER := 0;
  l_total_groups NUMBER;
  l_db_threads   NUMBER;
  l_min_overall_groups NUMBER;
BEGIN
  SELECT COUNT(*), COUNT(DISTINCT thread#) INTO l_total_groups, l_db_threads FROM v$log;
  l_min_overall_groups := 2 * GREATEST(l_db_threads, 1);

  FOR rec IN c_droppable_groups LOOP
    IF (l_total_groups - (l_count + 1)) >= l_min_overall_groups THEN
        l_droppable_list := l_droppable_list || rec.group# || ',';
        l_count := l_count + 1;
    END IF;
  END LOOP;

  IF l_count > 0 THEN
    l_droppable_list := RTRIM(l_droppable_list, ',');
    DBMS_OUTPUT.PUT_LINE('Suggested groups that *may* be safe to drop: ' || l_droppable_list);
    DBMS_OUTPUT.PUT_LINE('  (These are INACTIVE, ARCHIVED, and meet initial safety checks.)');
    DBMS_OUTPUT.PUT_LINE('  YOU MUST STILL VERIFY CAREFULLY before confirming their deletion.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('No groups currently meet all criteria for a safe drop suggestion.');
  END IF;
END;
/
PROMPT

ACCEPT confirm_pre_drop_input CHAR PROMPT 'Drop any existing groups BEFORE adding new? (Enter YES or NO): ' DEFAULT 'NO'

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_pre_drop_input'));
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y', 'NO', 'N') THEN
    DBMS_OUTPUT.PUT_LINE('!!! ERROR: Invalid input "&&confirm_pre_drop_input". Expected YES or NO. Halting script. !!!');
    RAISE_APPLICATION_ERROR(-20001, 'Invalid input for pre-drop confirmation.');
  END IF;
END;
/

DEFINE groups_to_drop_csv_pre = '' 

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __temp_drop_prompt_pre.sql REPLACE
SELECT
  CASE 
    WHEN UPPER(TRIM('&confirm_pre_drop_input')) IN ('YES', 'Y') THEN
      'PROMPT You chose to drop groups. WARNING: Destructive!' || CHR(10) ||
      'PROMPT   (Verify suggestions. Ensure INACTIVE, ARCHIVED, not last 2/thread.)' || CHR(10) ||
      'ACCEPT groups_to_drop_csv_pre CHAR PROMPT ''Groups to DROP (e.g. 1 or 1,2,3 / blank to skip): '''
    ELSE
      'REM Skipping prompt for groups to drop (pre-add phase).'
  END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF
SET PAGESIZE 200
@__temp_drop_prompt_pre.sql

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_pre_drop_input'));
  l_groups_to_drop_input VARCHAR2(100) := TRIM('&groups_to_drop_csv_pre');
  l_group_no       NUMBER;
  l_status         VARCHAR2(30);
  l_archived       VARCHAR2(3);
  l_members        NUMBER;
  l_total_groups   NUMBER;
  l_min_groups_needed NUMBER; 
  l_db_threads     NUMBER;
  l_sql            VARCHAR2(200);
  TYPE group_list_type IS TABLE OF NUMBER INDEX BY BINARY_INTEGER;
  l_group_array    group_list_type;
  l_idx            PLS_INTEGER;
  l_start_pos      PLS_INTEGER := 1;
  l_comma_pos      PLS_INTEGER;
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y') THEN
    DBMS_OUTPUT.PUT_LINE('Skipping pre-drop of log groups (confirmation was not YES/Y).');
    IF TRIM(l_groups_to_drop_input) IS NOT NULL AND l_confirm_input NOT IN ('YES','Y') THEN
        DBMS_OUTPUT.PUT_LINE('  (Note: Groups to drop input '''|| TRIM(l_groups_to_drop_input) ||''' was ignored).');
    END IF;
    RETURN;
  ELSIF TRIM(l_groups_to_drop_input) IS NULL AND l_confirm_input IN ('YES', 'Y') THEN
    DBMS_OUTPUT.PUT_LINE('No groups specified to drop, although pre-drop was confirmed YES. Skipping.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Attempting to drop specified log groups (PRE-ADD phase): ''' || l_groups_to_drop_input || '''');
  l_groups_to_drop_input := TRIM(l_groups_to_drop_input) || ','; 
  l_idx := 0;
  LOOP
    l_comma_pos := INSTR(l_groups_to_drop_input, ',', l_start_pos);
    EXIT WHEN l_comma_pos = 0 OR l_start_pos > LENGTH(l_groups_to_drop_input);
    BEGIN
      l_group_no := TO_NUMBER(TRIM(SUBSTR(l_groups_to_drop_input, l_start_pos, l_comma_pos - l_start_pos)));
      IF l_group_no IS NOT NULL THEN
         l_idx := l_idx + 1;
         l_group_array(l_idx) := l_group_no;
      END IF;
    EXCEPTION
      WHEN VALUE_ERROR THEN
        DBMS_OUTPUT.PUT_LINE('Warning: Invalid non-numeric value in group list: ''' ||
                             TRIM(SUBSTR(l_groups_to_drop_input, l_start_pos, l_comma_pos - l_start_pos)) || '''. Skipping.');
    END;
    l_start_pos := l_comma_pos + 1;
  END LOOP;

  IF l_group_array.COUNT = 0 THEN
      DBMS_OUTPUT.PUT_LINE('No valid group numbers parsed. Skipping drop operations.');
      RETURN;
  END IF;

  FOR i IN 1..l_group_array.COUNT LOOP
    l_group_no := l_group_array(i);
    DBMS_OUTPUT.PUT_LINE('--- Processing group# ' || l_group_no || ' for potential drop (PRE-ADD) ---');
    BEGIN
      SELECT COUNT(*), COUNT(DISTINCT THREAD#) INTO l_total_groups, l_db_threads FROM V$LOG;
      l_min_groups_needed := 2 * GREATEST(l_db_threads, 1); 
      SELECT STATUS, ARCHIVED, MEMBERS INTO l_status, l_archived, l_members FROM V$LOG WHERE GROUP# = l_group_no;

      IF l_status = 'CURRENT' THEN
        DBMS_OUTPUT.PUT_LINE('Error: Group ' || l_group_no || ' is CURRENT. Cannot drop. Switch logs first.');
      ELSIF l_status = 'ACTIVE' THEN
        DBMS_OUTPUT.PUT_LINE('Error: Group ' || l_group_no || ' is ACTIVE. Cannot drop. Needs to become INACTIVE.');
      ELSIF l_members = 0 THEN 
        DBMS_OUTPUT.PUT_LINE('Info: Group ' || l_group_no || ' has no members or already dropped/invalid.');
      ELSIF (l_total_groups - 1) < l_min_groups_needed THEN 
         DBMS_OUTPUT.PUT_LINE('Error: Cannot drop group ' || l_group_no || '. Would leave ' || (l_total_groups-1) ||
                              ' group(s); min required ' || l_min_groups_needed || ' for ' || l_db_threads || ' thread(s).');
      ELSE 
        DBMS_OUTPUT.PUT_LINE('Status for Group ' || l_group_no || ': ' || l_status || ', Archived: ' || l_archived);
        IF l_status = 'INACTIVE' AND l_archived = 'NO' THEN
            DBMS_OUTPUT.PUT_LINE('Warning: Group ' || l_group_no || ' INACTIVE but not ARCHIVED.');
            DBMS_OUTPUT.PUT_LINE('  Skipping drop for safety. Manually verify or ensure archiving.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('Proceeding with drop for Group ' || l_group_no || '.');
            l_sql := 'ALTER DATABASE DROP LOGFILE GROUP ' || l_group_no;
            DBMS_OUTPUT.PUT_LINE('  Executing: ' || l_sql);
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('  Group ' || l_group_no || ' drop DDL executed. Check alert log.');
        END IF;
      END IF;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Error: Group ' || l_group_no || ' not found in V$LOG.');
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error processing group ' || l_group_no || ': ' || SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('--- Finished PRE-ADD drop processing ---');
END;
/
PROMPT

-- Section 7: Add New Log Groups
PROMPT
PROMPT =========================================================================
PROMPT Section 7: Add New Log File Groups
PROMPT =========================================================================
PROMPT
PROMPT Size for new log files: &&ddl_log_size_mb.MB each.
PROMPT New files will be named using 'log_g<group_no>m<member_no>.dbf' convention.
PROMPT Paths for members:
PROMPT   Member 1 files in: &log_path1
PROMPT   Member 2 files in: &log_path2
PROMPT

COLUMN max_group_col NEW_VALUE max_existing_group NOPRINT
SELECT NVL(MAX(group#), 0) AS max_group_col FROM v$log;

COLUMN first_suggested_group_col NEW_VALUE first_suggested_new_group NOPRINT
SELECT TRIM(TO_CHAR(TO_NUMBER(NVL('&&max_existing_group','0')) + 1)) AS first_suggested_group_col FROM DUAL;

COLUMN example_new_groups_col NEW_VALUE example_new_groups_csv NOPRINT
SELECT TRIM(TO_CHAR(TO_NUMBER(NVL('&&max_existing_group','0')) + 1)) || ',' ||
       TRIM(TO_CHAR(TO_NUMBER(NVL('&&max_existing_group','0')) + 2)) || ',' ||
       TRIM(TO_CHAR(TO_NUMBER(NVL('&&max_existing_group','0')) + 3)) AS example_new_groups_col
FROM DUAL;

DEFINE groups_to_add_csv = '&&example_new_groups_csv' 
ACCEPT groups_to_add_csv CHAR DEFAULT '&&example_new_groups_csv' PROMPT 'Enter Group#(s) for NEW logs (Enter for Grps &&example_new_groups_csv; or e.g. &&first_suggested_new_group for one): '
PROMPT
SET DEFINE ON 
PROMPT --- Filesystem Space Check ---
PROMPT You intend to add log group(s): '&&groups_to_add_csv'.
PROMPT Each new group adds 2 members of &&ddl_log_size_mb.MB each.
PROMPT Example: If adding 3 groups of &&ddl_log_size_mb.MB, this would require
PROMPT approximately 6*&&ddl_log_size_mb.MB total space.
PROMPT
PROMPT Please MANUALLY check space on relevant filesystems using OS commands like:
PROMPT   df -h &&log_path1
PROMPT   df -h &&log_path2
PROMPT (Adjust for your OS/paths. Ensure sufficient free space BEFORE continuing.)
PROMPT
ACCEPT confirm_proceed_with_add_input CHAR PROMPT 'Space checked and OK to add groups? (Enter YES or NO): ' DEFAULT 'NO'

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_proceed_with_add_input'));
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y', 'NO', 'N') THEN
    DBMS_OUTPUT.PUT_LINE('!!! ERROR: Invalid input "&&confirm_proceed_with_add_input". Expected YES or NO. !!!');
    DBMS_OUTPUT.PUT_LINE('!!! Halting Add Logfile DDL. Please re-run section or script with valid input. !!!');
    RAISE_APPLICATION_ERROR(-20001, 'Invalid input for ADD LOGFILE confirmation.');
  END IF;
END;
/

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __add_skip_message.sql REPLACE
SELECT CASE 
            WHEN UPPER(TRIM('&confirm_proceed_with_add_input')) NOT IN ('YES', 'Y') THEN 
                'PROMPT --- User did not confirm space check or entered NO. SKIPPING Add Logfile DDL. ---'
            ELSE 
                'REM User confirmed to proceed with Add Logfile DDL.'
       END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF 
SET PAGESIZE 200 
@__add_skip_message.sql

DECLARE
  l_confirm_proceed VARCHAR2(10)  := UPPER(TRIM('&confirm_proceed_with_add_input'));
  l_groups_to_add_input VARCHAR2(100) := TRIM('&groups_to_add_csv');
  l_group_no        NUMBER;
  l_sql             VARCHAR2(1000);
  l_log_path1       VARCHAR2(256) := TRIM('&log_path1');
  l_log_path2       VARCHAR2(256) := TRIM('&log_path2');
  l_size_spec       VARCHAR2(20)  := REPLACE(TRIM('&&ddl_log_size_mb'),',','.') || 'M';
  
  TYPE group_list_type IS TABLE OF NUMBER INDEX BY BINARY_INTEGER;
  l_group_array     group_list_type;
  l_idx             PLS_INTEGER;
  l_start_pos       PLS_INTEGER := 1;
  l_comma_pos       PLS_INTEGER;
BEGIN
  IF l_confirm_proceed NOT IN ('YES', 'Y') THEN
    RETURN; 
  END IF;

  IF TRIM(l_groups_to_add_input) IS NULL THEN
    DBMS_OUTPUT.PUT_LINE('No group numbers specified to add. Skipping.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Attempting to ADD specified log groups: ''' || l_groups_to_add_input || '''');
  l_groups_to_add_input := TRIM(l_groups_to_add_input) || ','; 
  l_idx := 0;
  LOOP
    l_comma_pos := INSTR(l_groups_to_add_input, ',', l_start_pos);
    EXIT WHEN l_comma_pos = 0 OR l_start_pos > LENGTH(l_groups_to_add_input);
    BEGIN
      l_group_no := TO_NUMBER(TRIM(SUBSTR(l_groups_to_add_input, l_start_pos, l_comma_pos - l_start_pos)));
      IF l_group_no IS NOT NULL THEN
         l_idx := l_idx + 1;
         l_group_array(l_idx) := l_group_no;
      END IF;
    EXCEPTION
      WHEN VALUE_ERROR THEN
        DBMS_OUTPUT.PUT_LINE('Warning: Invalid non-numeric value in ADD group list: ''' ||
                             TRIM(SUBSTR(l_groups_to_add_input, l_start_pos, l_comma_pos - l_start_pos)) || '''. Skipping.');
    END;
    l_start_pos := l_comma_pos + 1;
  END LOOP;

  IF l_group_array.COUNT = 0 THEN
      DBMS_OUTPUT.PUT_LINE('No valid group numbers parsed to add. Skipping.');
      RETURN;
  END IF;
  
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('Reminder: Adding a group# that already exists will likely fail (ORA-01184).');
  DBMS_OUTPUT.PUT_LINE('If replacing existing groups, ensure they were DROPPED in Section 6 first.');
  DBMS_OUTPUT.PUT_LINE('---');

  FOR i IN 1..l_group_array.COUNT LOOP
    l_group_no := l_group_array(i);
    DBMS_OUTPUT.PUT_LINE('--- Preparing to add Group ' || l_group_no || ' ---');
    l_sql := 'ALTER DATABASE ADD LOGFILE GROUP ' || l_group_no || ' (''' ||
             l_log_path1 || '/log_g' || l_group_no || 'm1.dbf'', ''' ||
             l_log_path2 || '/log_g' || l_group_no || 'm2.dbf'') SIZE ' || l_size_spec || ' REUSE';
    DBMS_OUTPUT.PUT_LINE('Executing: ' || l_sql);
    BEGIN
      EXECUTE IMMEDIATE l_sql;
      DBMS_OUTPUT.PUT_LINE('Group ' || l_group_no || ' add DDL executed. Check alert log.');
    EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error adding group ' || l_group_no || ': ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('  (Often because group# ' || l_group_no || ' already exists).');
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('New log files addition attempt finished.');
END;
/
PROMPT

-- Section 7.5: Perform Log Switches and Optionally Drop Old Groups (POST-ADD)
SET DEFINE OFF
PROMPT
PROMPT =========================================================================
PROMPT Section 7.5: Perform Log Switches and Optionally Drop Old Groups (POST-ADD)
PROMPT =========================================================================
PROMPT
SET DEFINE ON
PROMPT Performing log switches to activate new/any UNUSED groups...
PROMPT -- If script appears to hang here, check database alert log for log switch issues.
PROMPT

DEFINE num_switches = '5' 
ACCEPT num_switches NUMBER DEFAULT 5 PROMPT 'Number of log switches to perform [5]: '

PROMPT -- Starting PL/SQL block for log switches...
DECLARE
  l_num_switches NUMBER := TO_NUMBER(NVL(TRIM('&num_switches'), '5'));
BEGIN
  IF l_num_switches > 0 THEN
    DBMS_OUTPUT.PUT_LINE('Performing ' || l_num_switches || ' log switches...');
    FOR i IN 1..l_num_switches LOOP
      DBMS_OUTPUT.PUT_LINE('Executing ALTER SYSTEM SWITCH LOGFILE; (Switch ' || i || ' of ' || l_num_switches || ')');
      EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Log switches complete.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Number of log switches is 0 or invalid. Skipping switches.');
  END IF;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error during log switches: ' || SQLERRM);
END;
/
PROMPT -- Finished PL/SQL block for log switches.
PROMPT

PROMPT Current Redo Log Groups status after switches (from V$LOG):
SET HEADING ON
SELECT GROUP#, THREAD#, SEQUENCE#, BYTES/1024/1024 AS SIZE_MB, MEMBERS, STATUS, ARCHIVED FROM V$LOG ORDER BY GROUP#;
SET HEADING OFF
PROMPT
PROMPT Identifying potential OLD groups to drop (INACTIVE, ARCHIVED, not violating min 2/thread rule)...
PROMPT (Excludes groups that were specified in '&groups_to_add_csv' during the ADD phase)
DECLARE
  CURSOR c_droppable_groups IS
    SELECT l.group#, l.thread#
    FROM v$log l
    LEFT JOIN (
        SELECT TO_NUMBER(TRIM(REGEXP_SUBSTR(TRIM('&groups_to_add_csv'), '[^,]+', 1, LEVEL))) AS group_no
        FROM dual
        WHERE TRIM('&groups_to_add_csv') IS NOT NULL 
        CONNECT BY LEVEL <= REGEXP_COUNT(TRIM('&groups_to_add_csv'), ',') + 1
    ) new_groups ON l.group# = new_groups.group_no
    WHERE new_groups.group_no IS NULL 
      AND l.STATUS = 'INACTIVE'
      AND l.ARCHIVED = 'YES'
      AND (SELECT COUNT(*) FROM v$log WHERE thread# = l.thread# AND group# != l.group#) >= 2 
    ORDER BY l.group#;
  l_droppable_list VARCHAR2(1000);
  l_count PLS_INTEGER := 0;
  l_total_groups NUMBER;
  l_db_threads   NUMBER;
  l_min_overall_groups NUMBER;
BEGIN
  IF TRIM('&groups_to_add_csv') IS NULL THEN 
    DBMS_OUTPUT.PUT_LINE('Cannot determine newly added groups to exclude for suggestions as no groups were added.');
    DBMS_OUTPUT.PUT_LINE('  Please manually identify any old groups you wish to drop.');
    RETURN;
  END IF;

  SELECT COUNT(*), COUNT(DISTINCT thread#) INTO l_total_groups, l_db_threads FROM v$log;
  l_min_overall_groups := 2 * GREATEST(l_db_threads, 1);

  FOR rec IN c_droppable_groups LOOP
    IF (l_total_groups - (l_count + 1)) >= l_min_overall_groups THEN
        l_droppable_list := l_droppable_list || rec.group# || ',';
        l_count := l_count + 1;
    END IF;
  END LOOP;

  IF l_count > 0 THEN
    l_droppable_list := RTRIM(l_droppable_list, ',');
    DBMS_OUTPUT.PUT_LINE('Suggested OLD groups (excluding any just added: &groups_to_add_csv) that *may* be safe to drop: ' || l_droppable_list);
    DBMS_OUTPUT.PUT_LINE('  (INACTIVE, ARCHIVED, and meet initial safety checks.)');
    DBMS_OUTPUT.PUT_LINE('  YOU MUST STILL VERIFY CAREFULLY before confirming their deletion.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('No obvious OLD groups (excluding any just added: &groups_to_add_csv) currently meet all criteria for a safe drop suggestion.');
  END IF;
END;
/
PROMPT

ACCEPT confirm_post_drop_input CHAR PROMPT 'Drop any OLD groups now? (Enter YES or NO): ' DEFAULT 'NO'

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_post_drop_input'));
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y', 'NO', 'N') THEN
    DBMS_OUTPUT.PUT_LINE('!!! ERROR: Invalid input "&&confirm_post_drop_input". Expected YES or NO. !!!');
    DBMS_OUTPUT.PUT_LINE('!!! Halting script to prevent unintended actions. Please re-run with valid input. !!!');
    RAISE_APPLICATION_ERROR(-20001, 'Invalid input for post-add drop confirmation.');
  END IF;
END;
/

DEFINE groups_to_drop_csv_post = '' 

SET TERMOUT OFF
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 300 TRIMSPOOL ON
SPOOL __temp_drop_prompt_post.sql REPLACE
SELECT
  CASE 
    WHEN UPPER(TRIM('&confirm_post_drop_input')) IN ('YES', 'Y') THEN
      'PROMPT You chose to drop old groups. Review V$LOG and suggestions above carefully!' || CHR(10) ||
      'PROMPT   (Ensure groups are OLD, INACTIVE, ARCHIVED, not last 2 per thread)' || CHR(10) ||
      'ACCEPT groups_to_drop_csv_post CHAR PROMPT ''OLD Groups to DROP (e.g. 1 or 1,2,3 / blank to skip): '''
    ELSE
      'REM Skipping prompt for dropping old groups post-add.'
  END
FROM DUAL;
SPOOL OFF
SET TERMOUT ON
SET HEADING ON
SET FEEDBACK OFF 
SET PAGESIZE 200 
@__temp_drop_prompt_post.sql

DECLARE
  l_confirm_input VARCHAR2(10) := UPPER(TRIM('&confirm_post_drop_input'));
  l_groups_to_drop_input VARCHAR2(100) := TRIM('&groups_to_drop_csv_post');
  l_group_no       NUMBER;
  l_status         VARCHAR2(30);
  l_archived       VARCHAR2(3);
  l_members        NUMBER;
  l_total_groups   NUMBER;
  l_min_groups_needed NUMBER; 
  l_db_threads     NUMBER;
  l_sql            VARCHAR2(200);
  TYPE group_list_type IS TABLE OF NUMBER INDEX BY BINARY_INTEGER;
  l_group_array    group_list_type;
  l_idx            PLS_INTEGER;
  l_start_pos      PLS_INTEGER := 1;
  l_comma_pos      PLS_INTEGER;
BEGIN
  IF l_confirm_input NOT IN ('YES', 'Y') THEN
    DBMS_OUTPUT.PUT_LINE('Skipping automated post-add drop of old log groups (confirmation not YES/Y).');
    IF TRIM(l_groups_to_drop_input) IS NOT NULL AND l_confirm_input NOT IN ('YES','Y') THEN 
        DBMS_OUTPUT.PUT_LINE('  (Note: Groups to drop input '''|| TRIM(l_groups_to_drop_input) ||''' was ignored).');
    END IF;
    RETURN;
  ELSIF TRIM(l_groups_to_drop_input) IS NULL AND l_confirm_input IN ('YES', 'Y') THEN 
    DBMS_OUTPUT.PUT_LINE('No groups specified to drop, although post-add drop was confirmed YES. Skipping drop.');
    RETURN;
  END IF;

  DBMS_OUTPUT.PUT_LINE('Attempting to drop specified OLD log groups (POST-ADD phase): ''' || l_groups_to_drop_input || '''');
  l_groups_to_drop_input := TRIM(l_groups_to_drop_input) || ','; 
  l_idx := 0;
  LOOP
    l_comma_pos := INSTR(l_groups_to_drop_input, ',', l_start_pos);
    EXIT WHEN l_comma_pos = 0 OR l_start_pos > LENGTH(l_groups_to_drop_input);
    BEGIN
      l_group_no := TO_NUMBER(TRIM(SUBSTR(l_groups_to_drop_input, l_start_pos, l_comma_pos - l_start_pos)));
      IF l_group_no IS NOT NULL THEN
         l_idx := l_idx + 1;
         l_group_array(l_idx) := l_group_no;
      END IF;
    EXCEPTION
      WHEN VALUE_ERROR THEN
        DBMS_OUTPUT.PUT_LINE('Warning: Invalid non-numeric value in group list: ''' ||
                             TRIM(SUBSTR(l_groups_to_drop_input, l_start_pos, l_comma_pos - l_start_pos)) || '''. Skipping.');
    END;
    l_start_pos := l_comma_pos + 1;
  END LOOP;

  IF l_group_array.COUNT = 0 THEN
      DBMS_OUTPUT.PUT_LINE('No valid group numbers parsed. Skipping drop operations.');
      RETURN;
  END IF;

  FOR i IN 1..l_group_array.COUNT LOOP
    l_group_no := l_group_array(i);
    DBMS_OUTPUT.PUT_LINE('--- Processing OLD group# ' || l_group_no || ' for potential drop (POST-ADD) ---');
    BEGIN
      SELECT COUNT(*), COUNT(DISTINCT THREAD#) INTO l_total_groups, l_db_threads FROM V$LOG;
      l_min_groups_needed := 2 * GREATEST(l_db_threads, 1); 
      SELECT STATUS, ARCHIVED, MEMBERS INTO l_status, l_archived, l_members FROM V$LOG WHERE GROUP# = l_group_no;

      IF l_status = 'CURRENT' THEN
        DBMS_OUTPUT.PUT_LINE('Error: Group ' || l_group_no || ' is CURRENT. Cannot drop.');
      ELSIF l_status = 'ACTIVE' THEN
        DBMS_OUTPUT.PUT_LINE('Error: Group ' || l_group_no || ' is ACTIVE. Needs more log switches.');
      ELSIF l_members = 0 THEN 
        DBMS_OUTPUT.PUT_LINE('Info: Group ' || l_group_no || ' has no members or already dropped/invalid.');
      ELSIF (l_total_groups - 1) < l_min_groups_needed THEN 
         DBMS_OUTPUT.PUT_LINE('Error: Cannot drop group ' || l_group_no || '. Would leave ' || (l_total_groups-1) ||
                              ' group(s); min required ' || l_min_groups_needed || ' for ' || l_db_threads || ' thread(s).');
      ELSE 
        DBMS_OUTPUT.PUT_LINE('Status for OLD Group ' || l_group_no || ': ' || l_status || ', Archived: ' || l_archived);
        IF l_status = 'INACTIVE' AND l_archived = 'NO' THEN
            DBMS_OUTPUT.PUT_LINE('Warning: OLD Group ' || l_group_no || ' INACTIVE but not ARCHIVED.');
            DBMS_OUTPUT.PUT_LINE('  Skipping drop for safety. Ensure archiving or manually verify.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('Proceeding with drop for OLD Group ' || l_group_no || '.');
            l_sql := 'ALTER DATABASE DROP LOGFILE GROUP ' || l_group_no;
            DBMS_OUTPUT.PUT_LINE('  Executing: ' || l_sql);
            EXECUTE IMMEDIATE l_sql;
            DBMS_OUTPUT.PUT_LINE('  OLD Group ' || l_group_no || ' drop DDL executed. Check alert log.');
        END IF;
      END IF;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Error: OLD Group ' || l_group_no || ' not found in V$LOG.');
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error processing OLD group ' || l_group_no || ': ' || SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('--- Finished POST-ADD drop processing ---');
END;
/
PROMPT

-- Section 8: Final Guidance
PROMPT
PROMPT =========================================================================
PROMPT Section 8: Final Guidance
PROMPT =========================================================================
PROMPT
PROMPT Redo log management operations attempted.
PROMPT 1. Please review all script output above and the database alert log for any errors from DDL commands.
PROMPT
PROMPT 2. Verify the current redo log configuration:
PROMPT    SELECT GROUP#, THREAD#, SEQUENCE#, BYTES/1024/1024 AS SIZE_MB, MEMBERS, STATUS, ARCHIVED FROM V$LOG ORDER BY GROUP#;
PROMPT
PROMPT 3. Ensure application performance is normal and log switching occurs at a reasonable frequency.
PROMPT
PROMPT 4. If any desired DROP operations were skipped (due to safety checks or your choice),
PROMPT    you may need to perform them manually after careful verification.
PROMPT
PROMPT =========================================================================
SET DEFINE OFF
PROMPT End of Redo Log Advisor and Management Helper Script
SET DEFINE ON
PROMPT =========================================================================
PROMPT
PROMPT Note: Temporary script files (__temp_*.sql and corresponding .LST files, if any)
PROMPT like __temp_customtime.sql, __check_data_found.sql, __add_skip_message.sql,
PROMPT __temp_drop_prompt_pre.sql, __temp_drop_prompt_post.sql
PROMPT may have been created. These can be manually deleted.
