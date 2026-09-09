-- Called only by redoctl.sh. Input is a CLOB bind, never executable plan text.
-- Oracle 19c+. Anonymous block: no permanent packages/tables are installed.
whenever oserror exit failure rollback
whenever sqlerror exit failure rollback
set define off sqlblanklines on
set serveroutput on size unlimited format wrapped
declare
    c_mib constant number := 1048576;
    l_doc json_object_t;
    l_cfg json_object_t;
    l_plan json_object_t;
    l_identity json_object_t;
    l_analysis json_object_t;
    l_original json_array_t := json_array_t();
    l_new json_array_t := json_array_t();
    type group_map is table of json_object_t index by pls_integer;
    l_old_map group_map;
    l_new_map group_map;
    type number_map is table of number index by varchar2(20);
    l_hour_bytes number_map;
    l_hour_weights number_map;
    l_dbid number;
    l_incarnation number;
    l_db_name varchar2(128);
    l_role varchar2(30);
    l_open varchar2(30);
    l_log_mode varchar2(30);
    l_platform varchar2(128);
    l_instance varchar2(128);
    l_host varchar2(256);
    l_version varchar2(128);
    l_thread number;
    l_cluster varchar2(10);
    l_dg_count number;
    l_other_threads number;
    l_standby_count number;
    l_sid varchar2(30);
    l_dir1 varchar2(200);
    l_dir2 varchar2(200);
    l_operation varchar2(10);
    l_days number;
    l_start_min number;
    l_end_min number;
    l_target_minutes number;
    l_headroom number;
    l_min_mb number;
    l_max_mb number;
    l_override_mb number;
    l_size_mb number;
    l_target_count number;
    l_reserve_mb number;
    l_wait_seconds number;
    l_poll_seconds number;
    l_max_switches number;
    l_runtime number;
    l_max_age number;
    l_block_size number;
    l_id varchar2(32);
    l_lock_handle varchar2(128);
    l_locked boolean := false;
    l_switches number := 0;
    l_wait_start number;
    l_present_new number := 0;
    l_missing_old number := 0;
    l_ready boolean;
    l_need_switch boolean;
    l_noop boolean := false;
    l_obj json_object_t;
    l_live json_object_t;
    l_number number;
    l_count number;
    l_key pls_integer;
    l_return number;

    procedure require(p_condition boolean, p_message varchar2) is
    begin
        if p_condition is null or not p_condition then
            raise_application_error(-20001, p_message);
        end if;
    end;

    procedure info(p_message varchar2) is
    begin
        dbms_output.put_line('REDO_INFO|' || p_message);
    end;

    function str(p_obj json_object_t, p_key varchar2) return varchar2 is
        l_value varchar2(32767);
    begin
        require(p_obj.has(p_key), 'Missing JSON key: ' || p_key);
        l_value := p_obj.get_string(p_key);
        require(l_value is not null, 'Empty JSON key: ' || p_key);
        return l_value;
    end;

    function integer_value(p_obj json_object_t, p_key varchar2,
                           p_min number, p_max number) return number is
        l_value varchar2(100);
        l_result number;
    begin
        l_value := str(p_obj, p_key);
        require(regexp_like(l_value, '^(0|[1-9][0-9]{0,15})$', 'c'),
                p_key || ' must be an unsigned integer');
        l_result := to_number(l_value, '9999999999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
        require(l_result between p_min and p_max, p_key || ' outside allowed range');
        return l_result;
    end;

    function fmt(p_value number) return varchar2 is
    begin
        return to_char(p_value, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
    end;

    function minutes(p_value varchar2, p_end boolean) return number is
    begin
        if p_end and p_value = '24:00' then return 1440; end if;
        require(regexp_like(p_value, '^([01][0-9]|2[0-3]):[0-5][0-9]$', 'c'),
                'Invalid time: ' || p_value);
        return to_number(substr(p_value, 1, 2)) * 60 + to_number(substr(p_value, 4, 2));
    end;

    function selected_minute(p_minute number) return boolean is
    begin
        if l_start_min < l_end_min then
            return p_minute >= l_start_min and p_minute < l_end_min;
        end if;
        return p_minute >= l_start_min or p_minute < l_end_min;
    end;

    procedure read_config is
    begin
        l_cfg := l_doc.get_object('config');
        require(l_cfg is not null, 'Missing configuration');
        l_sid := str(l_cfg, 'SAP_SID');
        require(regexp_like(l_sid, '^[A-Z][A-Z0-9]{2}$', 'c'), 'Invalid SAP_SID');
        require(regexp_like(str(l_cfg, 'DB_UNIQUE_NAME'), '^[A-Za-z][A-Za-z0-9_#$]{0,29}$', 'c'),
                'Invalid DB_UNIQUE_NAME');
        l_dir1 := str(l_cfg, 'MEMBER1_DIR');
        l_dir2 := str(l_cfg, 'MEMBER2_DIR');
        require(regexp_like(l_dir1, '^/[A-Za-z0-9_./-]+$', 'c') and
                regexp_like(l_dir2, '^/[A-Za-z0-9_./-]+$', 'c'), 'Invalid member directory');
        require(instr(l_dir1 || '/', '/../') = 0 and instr(l_dir2 || '/', '/../') = 0 and
                substr(l_dir1, -1) <> '/' and substr(l_dir2, -1) <> '/', 'Noncanonical member directory');
        l_days := integer_value(l_cfg, 'DAYS', 3, 7);
        require(l_days in (3,5,7), 'DAYS must be 3, 5, or 7');
        l_start_min := minutes(str(l_cfg, 'START_TIME'), false);
        l_end_min := minutes(str(l_cfg, 'END_TIME'), true);
        require(l_start_min <> l_end_min, 'Equal window endpoints are ambiguous');
        l_target_minutes := integer_value(l_cfg, 'TARGET_SWITCH_MINUTES', 1, 1440);
        l_headroom := integer_value(l_cfg, 'HEADROOM_PERCENT', 100, 1000);
        l_min_mb := integer_value(l_cfg, 'MIN_SIZE_MB', 4, 1048576);
        l_max_mb := integer_value(l_cfg, 'MAX_SIZE_MB', l_min_mb, 1048576);
        l_override_mb := integer_value(l_cfg, 'SIZE_MB', 0, l_max_mb);
        require(l_override_mb = 0 or l_override_mb >= l_min_mb, 'SIZE_MB is below MIN_SIZE_MB');
        l_target_count := integer_value(l_cfg, 'TARGET_GROUP_COUNT', 0, 32);
        l_operation := str(l_cfg, 'OPERATION');
        require(l_operation in ('add', 'replace'), 'Invalid OPERATION');
        require((l_operation = 'add' and l_target_count >= 1) or
                (l_operation = 'replace' and (l_target_count = 0 or l_target_count >= 2)),
                'add requires a group count; replace requires zero or at least two');
        l_reserve_mb := integer_value(l_cfg, 'RESERVE_MB', 0, 1048576);
        l_wait_seconds := integer_value(l_cfg, 'WAIT_SECONDS', 1, 7200);
        l_poll_seconds := integer_value(l_cfg, 'POLL_SECONDS', 1, 60);
        l_max_switches := integer_value(l_cfg, 'MAX_SWITCHES', 1, 256);
        l_runtime := integer_value(l_cfg, 'MAX_RUNTIME_SECONDS', 60, 86400);
        require(l_runtime > l_wait_seconds, 'MAX_RUNTIME_SECONDS must exceed WAIT_SECONDS');
        l_max_age := integer_value(l_cfg, 'PLAN_MAX_AGE_HOURS', 1, 168);
    end;

    procedure read_context is
    begin
        select dbid, resetlogs_change#, db_unique_name, database_role, open_mode,
               log_mode, platform_name
          into l_dbid, l_incarnation, l_db_name, l_role, l_open, l_log_mode, l_platform
          from v$database;
        select instance_name, host_name, version, thread#
          into l_instance, l_host, l_version, l_thread from v$instance;
        select value into l_cluster from v$parameter where name = 'cluster_database';
        select count(*) into l_dg_count from v$archive_dest
          where target = 'STANDBY' and destination is not null;
        select count(*) into l_standby_count from v$standby_log;
        select count(*) into l_other_threads from v$log where thread# <> l_thread;
        require(upper(l_db_name) = upper(str(l_cfg, 'DB_UNIQUE_NAME')), 'Connected DB_UNIQUE_NAME does not match configuration');
        require(upper(l_instance) = upper(:os_sid), 'Connected instance does not match ORACLE_SID');
        require(to_number(regexp_substr(l_version, '^[0-9]+')) >= 19, 'Oracle 19c or newer is required');
        require(to_number(sys_context('USERENV', 'CON_ID')) <= 1, 'Connect to CDB$ROOT or a non-CDB, not a PDB');
        l_identity := json_object_t();
        l_identity.put('dbid', l_dbid);
        l_identity.put('resetlogs_change', l_incarnation);
        l_identity.put('db_unique_name', l_db_name);
        l_identity.put('instance', l_instance);
        l_identity.put('host', l_host);
        l_identity.put('thread', l_thread);
        info('Database ' || l_db_name || ', DBID ' || fmt(l_dbid) || ', instance ' || l_instance ||
             ', host ' || l_host || ', thread ' || fmt(l_thread));
    end;

    procedure require_supported_target is
    begin
        require(l_role = 'PRIMARY' and l_open = 'READ WRITE' and l_log_mode = 'ARCHIVELOG',
                'Management requires PRIMARY, READ WRITE, ARCHIVELOG');
        require(upper(l_cluster) = 'FALSE' and l_other_threads = 0,
                'Management supports a single instance and one redo thread only');
        require(l_dg_count = 0 and l_standby_count = 0,
                'Data Guard/standby redo configuration detected: management is not supported by this version');
        require(instr(upper(l_platform), 'LINUX') > 0, 'Management requires a Linux database');
        require(lower(regexp_substr(l_host, '^[^.]+')) = lower(regexp_substr(:os_host, '^[^.]+')),
                'Run on the database host so filesystem checks examine the real redo storage');
    end;

    function get_group(p_id number) return json_object_t is
        l_group json_object_t := json_object_t();
        l_members json_array_t := json_array_t();
        l_t number; l_b number; l_bs number; l_seq number; l_m number;
        l_status varchar2(30); l_archived varchar2(3); l_bad number := 0;
    begin
        select thread#, bytes, blocksize, status, archived, sequence#, members
          into l_t, l_b, l_bs, l_status, l_archived, l_seq, l_m from v$log where group# = p_id;
        for rec in (select member, status from v$logfile where group# = p_id and type = 'ONLINE' order by member) loop
            require(regexp_like(rec.member, '^[ -~]+$', 'c'), 'Non-ASCII member path is not supported in plans');
            l_members.append(rec.member);
            if rec.status is not null then l_bad := l_bad + 1; end if;
        end loop;
        require(l_m = l_members.get_size, 'Inconsistent V$LOG/V$LOGFILE member counts');
        l_group.put('group_id', p_id); l_group.put('thread', l_t); l_group.put('bytes', l_b);
        l_group.put('block_size', l_bs); l_group.put('paths', l_members);
        l_group.put('status', l_status); l_group.put('archived', l_archived);
        l_group.put('sequence', l_seq); l_group.put('bad_members', l_bad);
        return l_group;
    exception when no_data_found then return null;
    end;

    function same_structure(p_actual json_object_t, p_expected json_object_t) return boolean is
        l_a json_array_t; l_e json_array_t;
        l_ac clob; l_ec clob;
    begin
        if p_actual is null or p_expected is null then return false; end if;
        l_a := p_actual.get_array('paths'); l_e := p_expected.get_array('paths');
        l_ac := l_a.to_clob; l_ec := l_e.to_clob;
        return p_actual.get_number('group_id') = p_expected.get_number('group_id') and
               p_actual.get_number('thread') = p_expected.get_number('thread') and
               p_actual.get_number('bytes') = p_expected.get_number('bytes') and
               p_actual.get_number('block_size') = p_expected.get_number('block_size') and
               dbms_lob.compare(l_ac, l_ec) = 0;
    end;

    procedure analyze is
        l_end date := trunc(sysdate, 'HH24');
        l_start date;
        l_when date;
        l_key varchar2(20);
        l_minute number;
        l_bytes number := 0;
        l_total number := 0;
        l_peak number := 0;
        l_hours number := 0;
        l_observed number := 0;
        l_copies number := 0;
        l_logs number := 0;
        l_long_logs number := 0;
        l_first date;
        l_last date;
        l_weight number;
    begin
        l_start := l_end - l_days;
        for h in 0 .. l_days * 24 - 1 loop
            l_when := l_start + h/24;
            l_key := to_char(l_when, 'YYYYMMDDHH24');
            l_weight := 0;
            for m in 0..59 loop
                if selected_minute(to_number(to_char(l_when, 'HH24'))*60 + m) then
                    l_weight := l_weight + 1/60;
                end if;
            end loop;
            if l_weight > 0 then
                l_hour_bytes(l_key) := 0; l_hour_weights(l_key) := l_weight;
                l_hours := l_hours + l_weight;
            end if;
        end loop;
        -- Keep archived history even after RMAN deletion. Count one logical log,
        -- not one physical copy/destination. Never mix RESETLOGS incarnations.
        for rec in (
            select thread#, sequence#, min(first_time) first_time, max(next_time) next_time,
                   max(blocks * block_size) log_bytes, count(*) copies
              from v$archived_log
             where resetlogs_change# = l_incarnation and thread# = l_thread and archived = 'YES'
               and first_time >= l_start and first_time < l_end
             group by resetlogs_change#, thread#, sequence#
        ) loop
            l_minute := to_number(to_char(rec.first_time, 'HH24'))*60 + to_number(to_char(rec.first_time, 'MI'));
            if selected_minute(l_minute) and rec.log_bytes > 0 then
                l_key := to_char(rec.first_time, 'YYYYMMDDHH24');
                require(l_hour_bytes.exists(l_key), 'Internal window bucketing error');
                l_hour_bytes(l_key) := l_hour_bytes(l_key) + rec.log_bytes;
                l_copies := l_copies + rec.copies - 1; l_logs := l_logs + 1;
                if (rec.next_time - rec.first_time)*24 > 1 then l_long_logs := l_long_logs + 1; end if;
                if l_first is null or rec.first_time < l_first then l_first := rec.first_time; end if;
                if l_last is null or rec.first_time > l_last then l_last := rec.first_time; end if;
            end if;
        end loop;
        l_key := l_hour_bytes.first;
        while l_key is not null loop
            l_bytes := l_hour_bytes(l_key);
            l_total := l_total + l_bytes;
            l_peak := greatest(l_peak, l_bytes/l_hour_weights(l_key));
            if l_bytes > 0 then l_observed := l_observed + l_hour_weights(l_key); end if;
            l_key := l_hour_bytes.next(l_key);
        end loop;
        l_analysis := json_object_t();
        l_analysis.put('method', 'Archived bytes attributed to FIRST_TIME hour; estimated generation, not measured rate');
        l_analysis.put('start_db_time', to_char(l_start, 'YYYY-MM-DD HH24:MI:SS'));
        l_analysis.put('end_db_time_exclusive', to_char(l_end, 'YYYY-MM-DD HH24:MI:SS'));
        l_analysis.put('window_start', str(l_cfg, 'START_TIME')); l_analysis.put('window_end_exclusive', str(l_cfg, 'END_TIME'));
        l_analysis.put('sampled_hours', round(l_hours, 4));
        l_analysis.put('observed_hours', round(l_observed, 4));
        l_analysis.put('unique_logs', l_logs); l_analysis.put('duplicate_records_ignored', l_copies);
        l_analysis.put('logs_spanning_over_one_hour', l_long_logs);
        l_analysis.put('total_mb', round(l_total/c_mib, 2));
        l_analysis.put('peak_mb_per_hour', round(l_peak/c_mib, 2));
        l_analysis.put('average_mb_per_hour', round(l_total/c_mib/l_hours, 2));
        l_analysis.put('earliest_log_start', to_char(l_first, 'YYYY-MM-DD HH24:MI:SS'));
        l_analysis.put('latest_log_start', to_char(l_last, 'YYYY-MM-DD HH24:MI:SS'));
        l_size_mb := null;
        if l_logs > 0 then
            l_size_mb := greatest(l_min_mb, ceil(l_peak/c_mib * l_target_minutes/60 * l_headroom/100));
            l_analysis.put('uncapped_recommendation_mb', l_size_mb);
        end if;
        if l_override_mb > 0 then l_size_mb := l_override_mb; end if;
        info('Analysis: ' || fmt(l_logs) || ' unique logs, ' || fmt(l_copies) || ' duplicate records ignored');
        info('Estimated peak ' || fmt(round(l_peak/c_mib,2)) || ' MiB/hour; average ' || fmt(round(l_total/c_mib/l_hours,2)) || ' MiB/hour');
        info('Observed ' || fmt(round(l_observed,2)) || ' of ' || fmt(round(l_hours,2)) || ' selected hours; empty buckets count as zero in the estimate');
        info('Archive history cannot distinguish idle periods from missing control-file records. Unarchived redo is absent. Review coverage before automatic sizing.');
        if l_long_logs > 0 then info('Logs spanning multiple hours make FIRST_TIME attribution less accurate.'); end if;
        if l_size_mb is null then info('No usable data: automatic sizing is unavailable; an explicit SIZE_MB is required.');
        elsif l_size_mb > l_max_mb then info('Recommendation exceeds MAX_SIZE_MB. Planning will stop rather than silently cap the size.');
        else info('Selected size: ' || fmt(l_size_mb) || ' MiB per member'); end if;
    end;

    function new_group(p_id number) return json_object_t is
        l_g json_object_t := json_object_t();
        l_p json_array_t := json_array_t();
        l_p1 varchar2(512); l_p2 varchar2(512);
    begin
        l_p1 := l_dir1 || '/log_g' || fmt(p_id) || 'm1_' || l_id || '.dbf';
        l_p2 := l_dir2 || '/log_g' || fmt(p_id) || 'm2_' || l_id || '.dbf';
        -- Store in the same lexical order returned by V$LOGFILE.
        if l_p1 < l_p2 then l_p.append(l_p1); l_p.append(l_p2);
        else l_p.append(l_p2); l_p.append(l_p1); end if;
        l_g.put('group_id', p_id); l_g.put('thread', l_thread);
        l_g.put('bytes', l_size_mb*c_mib); l_g.put('block_size', l_block_size); l_g.put('paths', l_p);
        return l_g;
    end;

    procedure make_plan is
        l_max_id number; l_n number; l_group json_object_t;
        l_explicit varchar2(4000); l_gpaths json_array_t;
        l_parent1 varchar2(512); l_parent2 varchar2(512);
        l_desired boolean := true;
    begin
        require_supported_target;
        require(l_size_mb is not null, 'No automatic size: supply SIZE_MB or collect representative archive history');
        require(l_size_mb <= l_max_mb, 'Automatic size exceeds MAX_SIZE_MB; review and explicitly change the policy or SIZE_MB');
        for rec in (select group# from v$log order by group#) loop
            l_group := get_group(rec.group#); l_original.append(l_group);
            if l_block_size is null then l_block_size := l_group.get_number('block_size'); end if;
            require(l_block_size = l_group.get_number('block_size'), 'Mixed redo block sizes require manual planning');
            l_gpaths := l_group.get_array('paths');
            if l_gpaths.get_size = 2 then
                l_parent1 := regexp_replace(l_gpaths.get_string(0), '/[^/]+$', '');
                l_parent2 := regexp_replace(l_gpaths.get_string(1), '/[^/]+$', '');
                if not ((l_parent1 = l_dir1 and l_parent2 = l_dir2) or (l_parent1 = l_dir2 and l_parent2 = l_dir1)) then l_desired := false; end if;
            else l_desired := false; end if;
            if l_group.get_number('bytes') <> l_size_mb*c_mib or l_group.get_number('bad_members') > 0 then l_desired := false; end if;
        end loop;
        require(l_original.get_size between 2 and 64, 'Expected 2..64 original groups');
        require(l_block_size in (512,1024,4096), 'Unsupported redo block size');
        if l_target_count = 0 then l_target_count := greatest(3, l_original.get_size); end if;
        require(l_target_count <= 32, 'At most 32 replacement/additional groups per plan');
        l_id := lower(rawtohex(sys_guid()));
        l_explicit := l_cfg.get_string('NEW_GROUPS');
        l_noop := l_operation = 'replace' and l_desired and l_original.get_size = l_target_count and l_explicit is null;
        if not l_noop then
            select max(group#) into l_max_id from (select group# from v$log union all select group# from v$standby_log);
            if l_explicit is not null then
                require(regexp_like(l_explicit, '^[1-9][0-9]{0,4}(,[1-9][0-9]{0,4})*$', 'c'), 'Invalid NEW_GROUPS');
                require(regexp_count(l_explicit, ',')+1 = l_target_count, 'NEW_GROUPS count must match the number of groups to create');
            end if;
            for i in 1..l_target_count loop
                if l_explicit is null then l_n := l_max_id+i;
                else l_n := to_number(regexp_substr(l_explicit, '[^,]+', 1, i)); end if;
                require(l_n between 1 and 65535, 'Group ID outside supported range');
                require(not l_new_map.exists(l_n), 'Duplicate NEW_GROUPS ID');
                select count(*) into l_count from (select group# from v$log union all select group# from v$standby_log) where group# = l_n;
                require(l_count = 0, 'Requested group ID already exists: ' || fmt(l_n));
                l_group := new_group(l_n); l_new_map(l_n) := l_group; l_new.append(l_group);
            end loop;
        end if;
        l_plan := json_object_t();
        l_plan.put('schema', 1); l_plan.put('kind', 'ora-redo-plan'); l_plan.put('plan_id', l_id);
        l_plan.put('created_utc', to_char(sys_extract_utc(systimestamp), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        l_plan.put('config', l_cfg); l_plan.put('identity', l_identity); l_plan.put('analysis', l_analysis);
        l_plan.put('size_mb', l_size_mb); l_plan.put('block_size', l_block_size);
        l_plan.put('target_count', l_target_count); l_plan.put('original_groups', l_original); l_plan.put('new_groups', l_new);
        if l_noop then info('Desired size, member directories and group count already match; plan has no DDL.');
        else info('Plan will ADD ' || fmt(l_new.get_size) || ' groups; operation=' || l_operation || '. Each group has two members.'); end if;
    end;

    procedure load_plan is
        l_expected json_object_t;
        l_created timestamp;
    begin
        require(str(l_doc, 'kind') = 'ora-redo-plan', 'Input is not an execution plan');
        l_plan := l_doc;
        l_id := str(l_plan, 'plan_id');
        require(regexp_like(l_id, '^[a-f0-9]{32}$', 'c'), 'Invalid plan ID');
        l_expected := l_plan.get_object('identity');
        require(l_expected is not null, 'Missing plan identity');
        require(integer_value(l_expected, 'dbid', 1, 9999999999999999) = l_dbid and
                integer_value(l_expected, 'resetlogs_change', 0, 9999999999999999) = l_incarnation and
                str(l_expected, 'db_unique_name') = l_db_name and
                str(l_expected, 'instance') = l_instance and str(l_expected, 'host') = l_host and
                integer_value(l_expected, 'thread', 1, 65535) = l_thread, 'Plan identity/incarnation does not match this database');
        l_size_mb := integer_value(l_plan, 'size_mb', l_min_mb, l_max_mb);
        l_block_size := integer_value(l_plan, 'block_size', 512, 4096);
        require(l_block_size in (512,1024,4096), 'Invalid plan block size');
        l_target_count := integer_value(l_plan, 'target_count', 1, 32);
        require(l_operation <> 'replace' or l_target_count >= 2, 'Replacement requires at least two groups');
        l_original := l_plan.get_array('original_groups'); l_new := l_plan.get_array('new_groups');
        require(l_original is not null and l_new is not null, 'Missing plan groups');
        require(l_original.get_size between 2 and 64 and l_new.get_size <= 32, 'Invalid plan group counts');
        require(l_new.get_size = 0 or l_new.get_size = l_target_count, 'Incomplete replacement/addition set');
        require(l_new.get_size > 0 or l_operation = 'replace', 'Empty add plan');
        for i in 0..l_original.get_size-1 loop
            l_obj := treat(l_original.get(i) as json_object_t);
            l_number := integer_value(l_obj, 'group_id', 1, 65535);
            require(not l_old_map.exists(l_number), 'Duplicate original ID');
            require(integer_value(l_obj, 'thread', 1, 65535) = l_thread, 'Original group belongs to another thread');
            l_old_map(l_number) := l_obj;
        end loop;
        if l_new.get_size > 0 then
            for i in 0..l_new.get_size-1 loop
                l_obj := treat(l_new.get(i) as json_object_t);
                l_number := integer_value(l_obj, 'group_id', 1, 65535);
                require(not l_old_map.exists(l_number) and not l_new_map.exists(l_number), 'Overlapping or duplicate new group ID');
                -- Rebuild every filename from validated config and plan ID. A plan
                -- cannot supply arbitrary executable SQL or arbitrary DROP paths.
                l_expected := new_group(l_number);
                require(same_structure(l_obj, l_expected), 'New group does not match the validated size, thread, block size or filenames');
                l_new_map(l_number) := l_expected;
            end loop;
        end if;
        l_noop := l_new.get_size = 0;
        l_created := to_timestamp(str(l_plan, 'created_utc'), 'FXYYYY-MM-DD"T"HH24:MI:SS"Z"');
        require(l_created <= sys_extract_utc(systimestamp) + interval '5' minute, 'Plan creation time is in the future');
        if l_created < sys_extract_utc(systimestamp) - numtodsinterval(l_max_age, 'HOUR') then
            l_count := 0;
            l_key := l_new_map.first;
            while l_key is not null loop
                l_live := get_group(l_key);
                if l_live is not null and same_structure(l_live, l_new_map(l_key)) then l_count := l_count+1; end if;
                l_key := l_new_map.next(l_key);
            end loop;
            require(:resume = 'YES' and l_count > 0, 'Plan expired; generate a fresh plan (only an already-started plan may resume after expiry)');
        end if;
    end;

    function new_groups_ready return boolean is
        l_g json_object_t;
        l_i pls_integer;
    begin
        l_i := l_new_map.first;
        while l_i is not null loop
            l_g := get_group(l_i);
            if not same_structure(l_g, l_new_map(l_i)) then return false; end if;
            if l_g.get_string('status') not in ('CURRENT','ACTIVE','INACTIVE') or
               l_g.get_number('sequence') = 0 or l_g.get_number('bad_members') <> 0 then return false; end if;
            l_i := l_new_map.next(l_i);
        end loop;
        return true;
    end;

    procedure verify_inventory(p_allow_progress boolean) is
        l_g json_object_t;
        l_i pls_integer;
        l_seen number := 0;
        l_context_ok number;
    begin
        -- Recheck role and incarnation as well as topology before each DDL step.
        select count(*) into l_context_ok from v$database d
         where d.dbid = l_dbid and d.resetlogs_change# = l_incarnation
           and d.database_role = 'PRIMARY' and d.open_mode = 'READ WRITE'
           and d.log_mode = 'ARCHIVELOG';
        require(l_context_ok = 1, 'Database role, open mode or incarnation changed');
        l_present_new := 0; l_missing_old := 0;
        for rec in (select group# from v$log order by group#) loop
            require(l_old_map.exists(rec.group#) or l_new_map.exists(rec.group#), 'Unexpected group appeared: ' || fmt(rec.group#));
            l_g := get_group(rec.group#);
            if l_old_map.exists(rec.group#) then
                require(same_structure(l_g, l_old_map(rec.group#)), 'Original group structure changed: ' || fmt(rec.group#));
                l_seen := l_seen + 1;
            else
                require(p_allow_progress, 'Plan was partially applied; inspect results and explicitly use --resume');
                require(same_structure(l_g, l_new_map(rec.group#)), 'New group ID collision or changed structure: ' || fmt(rec.group#));
                l_present_new := l_present_new + 1;
            end if;
        end loop;
        l_missing_old := l_old_map.count-l_seen;
        if l_missing_old > 0 then
            require(p_allow_progress and l_operation = 'replace' and not l_noop and
                    l_present_new = l_new_map.count and new_groups_ready,
                    'Original groups are missing without a complete, usable replacement set');
        end if;
    end;

    procedure emit_requirements is
        l_i pls_integer;
        l_g json_object_t;
        l_p json_array_t;
    begin
        dbms_output.put_line('REDO_RESERVE|' || fmt(l_reserve_mb*c_mib));
        dbms_output.put_line('REDO_TIMEOUT|' || fmt(l_runtime));
        l_i := l_new_map.first;
        while l_i is not null loop
            l_g := get_group(l_i);
            if l_g is null then
                l_g := l_new_map(l_i); l_p := l_g.get_array('paths');
                for m in 0..l_p.get_size-1 loop
                    dbms_output.put_line('REDO_FILE|' || l_p.get_string(m) || '|' || fmt(l_size_mb*c_mib));
                end loop;
            end if;
            l_i := l_new_map.next(l_i);
        end loop;
    end;

    procedure release_lock is
        l_rc number;
    begin
        if l_locked then
            l_rc := dbms_lock.release(l_lock_handle); l_locked := false;
        end if;
    end;

    procedure apply_plan is
        l_g json_object_t;
        l_p json_array_t;
        l_i pls_integer;
        l_stmt varchar2(4000);
        l_remaining number;
    begin
        if l_noop then info('No changes required.'); return; end if;
        dbms_lock.allocate_unique('ORA_REDO_MGMT_' || fmt(l_dbid), l_lock_handle, 86400);
        l_return := dbms_lock.request(l_lock_handle, dbms_lock.x_mode, 0, false);
        require(l_return = 0, 'Another redo-management session holds the database lock');
        l_locked := true;
        verify_inventory(:resume = 'YES');
        -- Complete and verify ALL additions before performing ANY switch/drop.
        l_i := l_new_map.first;
        while l_i is not null loop
            verify_inventory(true);
            l_g := get_group(l_i);
            if l_g is null then
                l_g := l_new_map(l_i); l_p := l_g.get_array('paths');
                l_stmt := 'ALTER DATABASE ADD LOGFILE GROUP ' || fmt(l_i) ||
                    ' (''' || l_p.get_string(0) || ''',''' || l_p.get_string(1) || ''') SIZE ' ||
                    fmt(l_size_mb) || 'M BLOCKSIZE ' || fmt(l_block_size);
                info('EXECUTE ' || l_stmt);
                execute immediate l_stmt;
                l_g := get_group(l_i);
                require(same_structure(l_g, l_new_map(l_i)), 'ADD verification failed');
            end if;
            l_i := l_new_map.next(l_i);
        end loop;
        verify_inventory(true);
        require(l_present_new = l_new_map.count, 'Not all new groups exist');
        if l_operation = 'add' then info('All added groups verified. No switches or drops requested.'); release_lock; return; end if;

        l_wait_start := dbms_utility.get_time;
        loop
            verify_inventory(true);
            l_ready := new_groups_ready; l_need_switch := not l_ready;
            -- Only UNUSED replacements need activation. Bad used members cannot
            -- be repaired by more switches; stop instead of hiding that fault.
            l_i := l_new_map.first;
            while l_i is not null loop
                l_g := get_group(l_i);
                if l_g.get_string('status') <> 'UNUSED' then
                    require(l_g.get_string('status') in ('CURRENT','ACTIVE','INACTIVE') and
                            l_g.get_number('bad_members') = 0, 'Replacement has an unhealthy used member/status');
                end if;
                l_i := l_new_map.next(l_i);
            end loop;
            l_i := l_old_map.first;
            while l_i is not null loop
                l_g := get_group(l_i);
                if l_g is not null then
                    if l_g.get_string('status') <> 'INACTIVE' or l_g.get_string('archived') <> 'YES' then l_ready := false; end if;
                    if l_g.get_string('status') in ('CURRENT','UNUSED') then l_need_switch := true; end if;
                    require(l_g.get_string('status') in ('CURRENT','ACTIVE','INACTIVE','UNUSED'), 'Unexpected original group status');
                end if;
                l_i := l_old_map.next(l_i);
            end loop;
            exit when l_ready;
            require((dbms_utility.get_time-l_wait_start)/100 < l_wait_seconds,
                    'Timed out waiting for replacement activation / original INACTIVE and ARCHIVED status');
            if l_need_switch then
                require(l_switches < l_max_switches, 'MAX_SWITCHES reached; inspect archiving/checkpoint progress');
                info('EXECUTE ALTER SYSTEM SWITCH LOGFILE; switch ' || fmt(l_switches+1));
                execute immediate 'ALTER SYSTEM SWITCH LOGFILE';
                l_switches := l_switches+1;
            end if;
            -- A switch starts a checkpoint but does not wait for its completion.
            -- If only ACTIVE/unarchived old logs remain, poll without more switches.
            dbms_session.sleep(l_poll_seconds);
        end loop;

        l_i := l_old_map.first;
        while l_i is not null loop
            verify_inventory(true);
            require(new_groups_ready, 'Replacement health changed before DROP');
            l_g := get_group(l_i);
            if l_g is not null then
                require(l_g.get_string('status') = 'INACTIVE' and l_g.get_string('archived') = 'YES',
                        'Original group is no longer INACTIVE/ARCHIVED; stop and resume after inspection');
                select count(*) into l_remaining from v$log where thread# = l_thread and group# <> l_i;
                require(l_remaining >= greatest(2,l_target_count), 'DROP would violate the per-thread retained-group count');
                info('EXECUTE ALTER DATABASE DROP LOGFILE GROUP ' || fmt(l_i));
                execute immediate 'ALTER DATABASE DROP LOGFILE GROUP ' || fmt(l_i);
                l_g := get_group(l_i);
                require(l_g is null, 'DROP verification failed');
                l_g := l_old_map(l_i); l_p := l_g.get_array('paths');
                for m in 0..l_p.get_size-1 loop
                    info('Dropped-group member path (filesystem files are retained; OMF may remove automatically): ' || l_p.get_string(m));
                end loop;
            end if;
            l_i := l_old_map.next(l_i);
        end loop;
        verify_inventory(true);
        require(l_missing_old = l_old_map.count and l_present_new = l_new_map.count, 'Final inventory verification failed');
        info('Replacement completed and final inventory verified.');
        release_lock;
    end;

    procedure emit_json(p_obj json_object_t) is
        l_clob clob;
        l_pos number := 1;
        l_piece varchar2(3500);
    begin
        l_clob := p_obj.to_clob;
        while l_pos <= dbms_lob.getlength(l_clob) loop
            l_piece := dbms_lob.substr(l_clob, 3500, l_pos);
            dbms_output.put_line('REDO_JSON|' || l_piece); l_pos := l_pos+length(l_piece);
        end loop;
    end;
begin
    require(:action in ('analyze','plan','check','apply'), 'Invalid action');
    require(:resume in ('YES','NO'), 'Invalid resume flag');
    l_doc := json_object_t.parse(:payload);
    require(integer_value(l_doc, 'schema', 1, 1) = 1, 'Unsupported schema');
    read_config;
    read_context;
    if :action in ('analyze','plan') then
        analyze;
        if :action = 'plan' then make_plan; emit_json(l_plan);
        else emit_json(l_analysis); end if;
        for rec in (select group#, thread#, bytes, status, archived from v$log order by group#) loop
            info('Group ' || fmt(rec.group#) || ', thread ' || fmt(rec.thread#) || ', ' ||
                 fmt(rec.bytes/c_mib) || ' MiB, ' || rec.status || ', archived=' || rec.archived);
        end loop;
    else
        require_supported_target;
        load_plan;
        verify_inventory(:resume = 'YES');
        if :action = 'check' then emit_requirements;
        else apply_plan; end if;
    end if;
    dbms_output.put_line('REDO_OK|' || :action);
exception when others then
    dbms_output.put_line('REDO_FAILURE|' || sqlerrm);
    dbms_output.put_line(dbms_utility.format_error_backtrace);
    begin release_lock; exception when others then null; end;
    raise;
end;
/
