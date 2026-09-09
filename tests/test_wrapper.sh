#!/usr/bin/env bash
# Tests the real Bash wrapper against a deliberately fake SQL*Plus executable.
# This does NOT test Oracle SQL/PLSQL or execute any database changes.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d /tmp/ora-redo-wrapper.XXXXXXXX)
cleanup() { [[ $scratch == /tmp/ora-redo-wrapper.* && -d $scratch ]] && rm -rf -- "$scratch"; }
trap cleanup EXIT
mkdir -p "$scratch/tool/sql" "$scratch/home/bin" "$scratch/mockbin" "$scratch/orig" "$scratch/mirror"
cp -- "$source_dir/redoctl.sh" "$scratch/tool/redoctl.sh"
cp -- "$source_dir/sql/redo_engine.sql" "$scratch/tool/sql/redo_engine.sql"
chmod +x "$scratch/tool/redoctl.sh"
touch "$scratch/home/bin/oracle"
export ORACLE_HOME="$scratch/home" ORACLE_SID=PRD
export FAKE_TRACE="$scratch/trace" FAKE_ROOT="$scratch" FAKE_CASE=good
export PATH="$scratch/mockbin:$PATH"
cat > "$ORACLE_HOME/bin/sqlplus" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
driver=${!#}; driver=${driver#@}
phase=$(sed -n "s/.*:action := '\([^']*\)';.*/\1/p" "$driver")
printf '%s\n' "$phase" >> "$FAKE_TRACE"
if [[ $FAKE_CASE == sp2 ]]; then echo 'SP2-0310: unable to open file'; echo "REDO_OK|$phase"; exit 0; fi
if [[ $FAKE_CASE == ora ]]; then echo 'ORA-20001: validation failed'; exit 1; fi
if [[ $FAKE_CASE == no_marker ]]; then echo 'Disconnected'; exit 0; fi
if [[ $FAKE_CASE == failed_check && $phase == check ]]; then echo 'ORA-20001: drift'; exit 1; fi
if [[ $FAKE_CASE == failed_apply && $phase == apply ]]; then echo 'ORA-00301: add failed'; exit 1; fi
if [[ $phase == analyze || $phase == plan ]]; then
    echo 'REDO_JSON|{"schema":'
    echo 'REDO_JSON|1}'
fi
if [[ $phase == check ]]; then
    echo 'REDO_RESERVE|0'; echo 'REDO_TIMEOUT|60'
    if [[ $FAKE_CASE == malformed ]]; then
        echo 'REDO_FILE|/tmp/invalid;command|10'
    else
        printf 'REDO_FILE|%s/orig/new1.dbf|6291456\n' "$FAKE_ROOT"
        printf 'REDO_FILE|%s/mirror/new2.dbf|6291456\n' "$FAKE_ROOT"
    fi
fi
echo "REDO_OK|$phase"
FAKE
cat > "$scratch/mockbin/df" <<'FAKE'
#!/usr/bin/env bash
echo 'Avail'
if [[ $FAKE_CASE == shared_space ]]; then echo 10485760; else echo 1073741824; fi
FAKE
chmod +x "$ORACLE_HOME/bin/sqlplus" "$scratch/mockbin/df"
cat > "$scratch/config" <<EOF
SAP_SID=PRD
DB_UNIQUE_NAME=PRD
MEMBER1_DIR=$scratch/orig
MEMBER2_DIR=$scratch/mirror
SIZE_MB=512
EOF
tool="$scratch/tool/redoctl.sh"
passed=0
pass() { passed=$((passed+1)); printf 'PASS %s\n' "$1"; }
expect_failure() {
    if "$@" > "$scratch/last.log" 2>&1; then cat "$scratch/last.log"; echo 'Expected failure' >&2; exit 1; fi
}
make_plan() {
    local dest=$1
    FAKE_CASE=good "$tool" plan --config "$scratch/config" --output "$dest" > "$scratch/last.log" 2>&1
}
expect_failure "$tool" nonsense
pass 'unknown command rejected'
for change in 'UNRECOGNIZED=yes' 'SAP_SID=123' 'SIZE_MB=1.5' 'DAYS=4' 'START_TIME=99:99'; do
    sed "/^${change%%=*}=/d" "$scratch/config" > "$scratch/bad"
    if [[ $change == START_TIME=* ]]; then printf 'WINDOW=custom\n' >> "$scratch/bad"; fi
    printf '%s\n' "$change" >> "$scratch/bad"
    : > "$FAKE_TRACE"
    expect_failure "$tool" analyze --config "$scratch/bad" --output "$scratch/invalid-output"
    [[ ! -s $FAKE_TRACE ]]
    pass "invalid config rejected before connection: $change"
done
cp "$scratch/config" "$scratch/bad"
printf 'SAP_SID=XYZ\n' >> "$scratch/bad"
expect_failure "$tool" analyze --config "$scratch/bad"
pass 'duplicate keys are rejected'
cp "$scratch/config" "$scratch/bad"
# Deliberately test a literal shell injection string.
# shellcheck disable=SC2016
printf 'NEW_GROUPS=$(touch %s/injected)\n' "$scratch" >> "$scratch/bad"
expect_failure "$tool" analyze --config "$scratch/bad"
[[ ! -e $scratch/injected ]]
pass 'config shell substitution is never executed'
for failure in sp2 ora no_marker; do
    export FAKE_CASE=$failure
    expect_failure "$tool" analyze --config "$scratch/config" --output "$scratch/$failure"
    pass "SQL*Plus failure detected: $failure"
done
export FAKE_CASE=good
: > "$FAKE_TRACE"
"$tool" analyze --config "$scratch/config" --output "$scratch/analysis" > "$scratch/last.log" 2>&1
[[ $(cat "$FAKE_TRACE") == analyze && $(cat "$scratch/analysis/analysis.json") == '{"schema":1}' ]]
pass 'analysis invokes only analysis and joins JSON chunks exactly'
make_plan "$scratch/plan"
[[ $(cat "$scratch/plan/plan.json") == '{"schema":1}' ]]
(cd "$scratch/plan" && sha256sum --check --status plan.sha256)
pass 'plan artifact and checksum created'
expect_failure "$tool" plan --config "$scratch/config" --output "$scratch/plan"
pass 'existing output never overwritten'
cp "$scratch/plan/plan.json" "$scratch/saved.json"
echo 'tampered' >> "$scratch/plan/plan.json"
: > "$FAKE_TRACE"
expect_failure "$tool" apply --plan "$scratch/plan"
[[ ! -s $FAKE_TRACE ]]
cp "$scratch/saved.json" "$scratch/plan/plan.json"
pass 'tampered plan rejected before connection'
for failure in failed_check shared_space malformed; do
    export FAKE_CASE=$failure
    : > "$FAKE_TRACE"
    expect_failure "$tool" apply --plan "$scratch/plan"
    [[ $(cat "$FAKE_TRACE") == check && ! -e $scratch/plan/attempted ]]
    pass "preflight prevents apply: $failure"
done
export FAKE_CASE=good
touch "$scratch/orig/new1.dbf"
expect_failure "$tool" apply --plan "$scratch/plan"
[[ ! -e $scratch/plan/attempted ]]
rm -- "$scratch/orig/new1.dbf"
pass 'existing destination file rejected'
export FAKE_CASE=failed_apply
expect_failure "$tool" apply --plan "$scratch/plan"
[[ -s $scratch/plan/attempted ]]
pass 'uncertain/failed apply persists attempted marker'
export FAKE_CASE=good
: > "$FAKE_TRACE"
expect_failure "$tool" apply --plan "$scratch/plan"
[[ ! -s $FAKE_TRACE ]]
pass 'repeat attempt requires explicit resume'
"$tool" apply --plan "$scratch/plan" --resume > "$scratch/last.log" 2>&1
[[ $(cat "$FAKE_TRACE") == $'check\napply' ]]
pass 'resume performs preflight then apply'
exec 8>"$scratch/plan/apply.lock"
flock -n 8
expect_failure "$tool" apply --plan "$scratch/plan" --resume
flock -u 8
pass 'concurrent apply of same plan rejected'
printf '%s Bash wrapper tests passed. Oracle execution remains untested by this suite.\n' "$passed"
