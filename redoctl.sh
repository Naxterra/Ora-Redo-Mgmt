#!/usr/bin/env bash
# SAP Oracle redo analysis and replacement. Runtime: Bash, SQL*Plus, GNU utilities.
set -euo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  redoctl.sh analyze --config FILE [--output DIR]
  redoctl.sh plan    --config FILE --output NEW_PLAN_DIR
  redoctl.sh apply   --plan PLAN_DIR [--resume]

Run on the database host as the Oracle software owner, with ORACLE_HOME and
ORACLE_SID set. Authentication is local / AS SYSDBA. There are no prompts.
analyze and plan perform no database changes. Only apply executes redo DDL.
After a partial/uncertain apply, inspect its log, then use the SAME plan --resume.
EOF
}
[[ $# -gt 0 ]] || { usage; exit 2; }
action=$1; shift
case "$action" in analyze|plan|apply) ;; -h|--help) usage; exit 0 ;; *) usage; exit 2 ;; esac
config='' output='' plan_dir='' resume=NO
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|--output|--plan)
            [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"
            case "$1" in --config) config=$2 ;; --output) output=$2 ;; --plan) plan_dir=$2 ;; esac
            shift 2 ;;
        --resume) resume=YES; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
if [[ $action == apply ]]; then
    [[ -n $plan_dir && -z $config && -z $output ]] || die 'apply requires only --plan and optional --resume'
else
    [[ -n $config && -z $plan_dir && $resume == NO ]] || die "$action requires --config"
    [[ $action != plan || -n $output ]] || die 'plan requires --output NEW_PLAN_DIR'
fi

for utility in awk od tr fold grep sed hostname stat df timeout flock mktemp sha256sum sync head cp date dirname; do
    command -v "$utility" >/dev/null || die "Required utility not found: $utility"
done
[[ $(uname -s) == Linux ]] || die 'Run this tool on the Linux database host'
[[ ${ORACLE_SID:-} =~ ^[A-Za-z][A-Za-z0-9_]{0,29}$ ]] || die 'Set a valid ORACLE_SID'
[[ -n ${ORACLE_HOME:-} && -x $ORACLE_HOME/bin/sqlplus ]] || die 'Set ORACLE_HOME to the database home containing bin/sqlplus'
local_host=$(hostname)
[[ $local_host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'Unsupported local hostname'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# SQL*Plus START paths cannot carry SQL*Plus metacharacters. Payloads are hex data.
safe_path() { [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != *'/../'* && $1 != */.. ]]; }
safe_path "$script_dir" || die 'Install the tool under an absolute path without spaces or metacharacters'

declare -A cfg=(
    [SAP_SID]='' [DB_UNIQUE_NAME]='' [MEMBER1_DIR]='' [MEMBER2_DIR]=''
    [DAYS]=3 [WINDOW]=whole [START_TIME]=00:00 [END_TIME]=24:00
    [TARGET_SWITCH_MINUTES]=60 [HEADROOM_PERCENT]=150 [MIN_SIZE_MB]=100
    [MAX_SIZE_MB]=8192 [SIZE_MB]=0 [TARGET_GROUP_COUNT]=0 [NEW_GROUPS]=''
    [OPERATION]=replace [RESERVE_MB]=1024 [WAIT_SECONDS]=600 [POLL_SECONDS]=5
    [MAX_SWITCHES]=32 [MAX_RUNTIME_SECONDS]=1800 [PLAN_MAX_AGE_HOURS]=24
)

load_config() {
    [[ -f $config ]] || die "Configuration not found: $config"
    local line key value
    declare -A seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "Expected literal KEY=value: $line"
        key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
        [[ -v cfg[$key] ]] || die "Unknown config key: $key"
        [[ ! -v seen[$key] ]] || die "Duplicate config key: $key"
        seen[$key]=1; cfg[$key]=$value
    done < "$config"
    [[ ${cfg[SAP_SID]} =~ ^[A-Z][A-Z0-9]{2}$ ]] || die 'SAP_SID must be three uppercase alphanumeric characters, starting with a letter'
    [[ ${cfg[DB_UNIQUE_NAME]} =~ ^[A-Za-z][A-Za-z0-9_#$]{0,29}$ ]] || die 'Set DB_UNIQUE_NAME explicitly'
    cfg[MEMBER1_DIR]=${cfg[MEMBER1_DIR]:-/oracle/${cfg[SAP_SID]}/origlogA}
    cfg[MEMBER2_DIR]=${cfg[MEMBER2_DIR]:-/oracle/${cfg[SAP_SID]}/mirrlogA}
    for key in MEMBER1_DIR MEMBER2_DIR; do
        value=${cfg[$key]%/}
        if ! safe_path "$value" || [[ ${#value} -gt 200 ]]; then
            die "Invalid absolute filesystem path: $key"
        fi
        cfg[$key]=$value
    done
    for key in DAYS TARGET_SWITCH_MINUTES HEADROOM_PERCENT MIN_SIZE_MB MAX_SIZE_MB SIZE_MB TARGET_GROUP_COUNT RESERVE_MB WAIT_SECONDS POLL_SECONDS MAX_SWITCHES MAX_RUNTIME_SECONDS PLAN_MAX_AGE_HOURS; do
        [[ ${cfg[$key]} =~ ^(0|[1-9][0-9]{0,7})$ ]] || die "$key must be an integer without leading zeros"
    done
    [[ ${cfg[DAYS]} =~ ^(3|5|7)$ ]] || die 'DAYS must be 3, 5, or 7'
    (( cfg[MAX_RUNTIME_SECONDS] >= 60 && cfg[MAX_RUNTIME_SECONDS] <= 86400 )) || die 'MAX_RUNTIME_SECONDS must be between 60 and 86400'
    case ${cfg[WINDOW]} in
        whole) cfg[START_TIME]=00:00; cfg[END_TIME]=24:00 ;;
        day) cfg[START_TIME]=08:00; cfg[END_TIME]=18:00 ;;
        night) cfg[START_TIME]=18:00; cfg[END_TIME]=08:00 ;;
        custom) ;;
        *) die 'WINDOW must be whole, day, night, or custom' ;;
    esac
    [[ ${cfg[START_TIME]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die 'Invalid START_TIME'
    [[ ${cfg[END_TIME]} =~ ^(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)$ ]] || die 'Invalid END_TIME'
    [[ ${cfg[START_TIME]} != "${cfg[END_TIME]}" ]] || die 'START_TIME and END_TIME must differ; use WINDOW=whole for a full day'
    [[ ${cfg[OPERATION]} =~ ^(replace|add)$ ]] || die 'OPERATION must be replace or add'
    [[ -z ${cfg[NEW_GROUPS]} || ${cfg[NEW_GROUPS]} =~ ^[1-9][0-9]{0,4}(,[1-9][0-9]{0,4})*$ ]] || die 'NEW_GROUPS must be a comma-separated integer list'
}

if [[ $action == apply ]]; then
    [[ -f $ORACLE_HOME/bin/oracle && $EUID -eq $(stat -c %u "$ORACLE_HOME/bin/oracle") ]] || die 'apply must run as the owner of ORACLE_HOME/bin/oracle'
    plan_dir=$(cd -- "$plan_dir" && pwd -P) || die 'Plan directory not found'
    safe_path "$plan_dir" || die 'Unsupported plan directory path'
    [[ -f $plan_dir/plan.json && -f $plan_dir/plan.sha256 ]] || die 'Incomplete plan directory'
    (cd -- "$plan_dir" && sha256sum --check --status plan.sha256) || die 'Plan checksum mismatch'
    exec 9>"$plan_dir/apply.lock"
    flock -n 9 || die 'Another process is applying this plan'
    if [[ -e $plan_dir/attempted && $resume != YES ]]; then
        die 'This plan has already been attempted. Inspect logs and use --resume to reconcile it.'
    fi
    run_dir=$(mktemp -d "$plan_dir/apply.XXXXXXXX")
    cp -- "$plan_dir/plan.json" "$run_dir/input.json"
else
    load_config
    output=${output:-./redo-analysis-$(date -u +%Y%m%dT%H%M%SZ)-$$}
    [[ ! -e $output ]] || die "Output already exists: $output"
    mkdir -m 700 -- "$output"
    run_dir=$(cd -- "$output" && pwd -P)
    safe_path "$run_dir" || die 'Unsupported output directory path'
    {
        printf '{"schema":1,"config":{'
        sep=
        for key in SAP_SID DB_UNIQUE_NAME MEMBER1_DIR MEMBER2_DIR DAYS START_TIME END_TIME TARGET_SWITCH_MINUTES HEADROOM_PERCENT MIN_SIZE_MB MAX_SIZE_MB SIZE_MB TARGET_GROUP_COUNT NEW_GROUPS OPERATION RESERVE_MB WAIT_SECONDS POLL_SECONDS MAX_SWITCHES MAX_RUNTIME_SECONDS PLAN_MAX_AGE_HOURS; do
            printf '%s"%s":"%s"' "$sep" "$key" "${cfg[$key]}"; sep=,
        done
        printf '}}\n'
    } > "$run_dir/input.json"
fi
[[ $(stat -c %s "$run_dir/input.json") -le 1048576 ]] || die 'Input exceeds 1 MiB'

invoke_sql() {
    local phase=$1 seconds=$2 logfile=$3 hex rc=0
    local driver="$run_dir/driver.sql"
    {
        printf '%s\n' 'whenever oserror exit failure rollback' 'whenever sqlerror exit failure rollback'
        printf '%s\n' 'set echo off verify off feedback off heading off pagesize 0' 'set define off sqlblanklines on' 'set serveroutput on size unlimited format wrapped' 'set linesize 32767 trimspool on'
        printf '%s\n' 'variable payload clob' 'variable action varchar2(20)' 'variable resume varchar2(3)' 'variable os_sid varchar2(30)' 'variable os_host varchar2(256)'
        printf 'begin\n :payload := empty_clob();\n :action := '\''%s'\'';\n :resume := '\''%s'\'';\n :os_sid := '\''%s'\'';\n :os_host := '\''%s'\'';\nend;\n/\n' "$phase" "$resume" "$ORACLE_SID" "$local_host"
        # Never treat configuration/plan content as executable SQL*Plus text.
        while IFS= read -r hex || [[ -n $hex ]]; do
            [[ -z $hex ]] && continue
            printf 'begin :payload := :payload || to_clob(utl_raw.cast_to_varchar2(hextoraw('\''%s'\''))); end;\n/\n' "$hex"
        done < <(od -An -v -tx1 "$run_dir/input.json" | tr -d ' \n' | fold -w 2000)
        printf '@%s/sql/redo_engine.sql\n' "$script_dir"
        printf '%s\n' 'exit success rollback'
    } > "$driver"
    printf 'Running %s; log: %s\n' "$phase" "$logfile"
    timeout --signal=TERM --kill-after=15s "${seconds}s" \
        "$ORACLE_HOME/bin/sqlplus" -L -S '/ as sysdba' @"$driver" > "$logfile" 2>&1 || rc=$?
    # SQL*Plus can exit 0 after SP2 errors. A fresh, phase-specific marker is mandatory.
    if (( rc != 0 )) || grep -Eq '^[[:space:]]*(ORA-|SP2-|PLS-|TNS-|ERROR at line)' "$logfile" ||
        ! grep -Fxq "REDO_OK|$phase" "$logfile"; then
        cat -- "$logfile" >&2
        die "$phase failed (exit $rc). DDL may already have committed; inspect the log and database before resuming."
    fi
    grep '^REDO_INFO|' "$logfile" | sed 's/^REDO_INFO|//' || true
}

if [[ $action == analyze || $action == plan ]]; then
    invoke_sql "$action" "${cfg[MAX_RUNTIME_SECONDS]}" "$run_dir/$action.log"
    result_file="$run_dir/analysis.json"
    [[ $action != plan ]] || result_file="$run_dir/plan.json"
    awk 'index($0,"REDO_JSON|")==1 {printf "%s",substr($0,11)} END {print ""}' "$run_dir/$action.log" > "$result_file"
    [[ -s $result_file && $(head -c 1 "$result_file") == '{' ]] || die 'No result JSON returned'
    if [[ $action == plan ]]; then
        (cd -- "$run_dir" && sha256sum plan.json > plan.sha256)
        sync -f "$run_dir/plan.json"
        printf 'Plan saved: %s/plan.json\nApply: %s/redoctl.sh apply --plan %s\n' "$run_dir" "$script_dir" "$run_dir"
    fi
    exit 0
fi

invoke_sql check 120 "$run_dir/check.log"
reserve='' timeout_seconds='' file_count=0
declare -A required=() free=()
while IFS='|' read -r tag first second extra; do
    case "$tag" in
        REDO_RESERVE) reserve=$first ;;
        REDO_TIMEOUT) timeout_seconds=$first ;;
        REDO_FILE)
            if ! safe_path "$first" || [[ ! $second =~ ^[1-9][0-9]{0,14}$ || -n $extra ]]; then
                die 'Malformed file requirement from SQL'
            fi
            [[ ! -e $first && ! -L $first ]] || die "File already exists; REUSE is forbidden: $first"
            dir=$(dirname -- "$first")
            [[ -d $dir && -w $dir ]] || die "Directory missing or not writable by the Oracle owner: $dir"
            device=$(stat -c %d -- "$dir")
            available=$(df -B1 --output=avail -- "$dir" | awk 'NR==2 {print $1}')
            [[ $device =~ ^[0-9]+$ && $available =~ ^[0-9]+$ ]] || die 'Could not determine filesystem capacity'
            required[$device]=$(( ${required[$device]:-0} + second ))
            if [[ ! -v free[$device] || $available -lt ${free[$device]} ]]; then free[$device]=$available; fi
            file_count=$((file_count + 1)) ;;
    esac
done < "$run_dir/check.log"
[[ $reserve =~ ^[0-9]{1,15}$ && $timeout_seconds =~ ^[1-9][0-9]{0,4}$ ]] || die 'Missing execution limits from preflight'
for device in "${!required[@]}"; do
    (( free[$device] >= required[$device] + reserve )) || die "Insufficient free space on device $device: need ${required[$device]} + $reserve reserve, have ${free[$device]}"
done
printf 'Filesystem preflight passed for %s new members.\n' "$file_count"
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) $run_dir" >> "$plan_dir/attempted"
sync -f "$plan_dir/attempted"
invoke_sql apply "$timeout_seconds" "$run_dir/apply.log"
printf 'Apply completed. Result and retained old-file paths: %s/apply.log\n' "$run_dir"
