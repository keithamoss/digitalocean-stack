#!/bin/bash
# Isolated regression checks: all AWS and Discord calls use local fixtures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
STACK="$TEST_DIR/stack"
STATE="$STACK/backups/monitoring/state"
mkdir -p "$STATE" "$STACK/backups/secrets" "$STACK/backups/lib" \
    "$STACK/backups/monitoring/"{costs,scripts,heartbeat} "$TEST_DIR/bin"
cp "$ROOT_DIR/backups/config.sh" "$STACK/backups/config.sh"
cp "$ROOT_DIR/backups/lib/wrapper-lib.sh" "$STACK/backups/lib/wrapper-lib.sh"
cp "$ROOT_DIR/backups/monitoring/costs/s3-cost-report.sh" "$STACK/backups/monitoring/costs/"
cp "$ROOT_DIR/backups/monitoring/heartbeat/heartbeat-wrapper.sh" "$STACK/backups/monitoring/heartbeat/"
cp "$ROOT_DIR/backups/monitoring/scripts/backup-status.sh" "$STACK/backups/monitoring/scripts/backup-status-real.sh"
touch "$STACK/backups/secrets/aws.env"
export STATE MOCK_EVENTS="$TEST_DIR/events" MOCK_CALLS="$TEST_DIR/calls"
export PATH="$TEST_DIR/bin:$PATH"
export TZ=Australia/Perth
MONTH="$(date +%Y-%m)"
REPORT="$STACK/backups/monitoring/costs/s3-cost-report.sh"
LATEST="$STATE/s3-costs-latest.json"
SNAPSHOT="$STATE/s3-costs-$MONTH.json"

cat > "$TEST_DIR/bin/aws" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == "ce" ]] && exit 1
[[ "$1 $2" == "s3api list-objects-v2" ]] || exit 90
shift 2
prefix="" token=0 explicit=false max_keys=""
while (($#)); do
    case "$1" in
        --prefix) prefix="$2"; shift 2 ;;
        --continuation-token) token="$2"; shift 2 ;;
        --no-paginate) explicit=true; shift ;;
        --max-keys) max_keys="$2"; shift 2 ;;
        --bucket|--output) shift 2 ;;
        *) exit 91 ;;
    esac
done
$explicit && [[ "$max_keys" == "1000" ]] || exit 92
echo "$prefix $token" >> "$MOCK_CALLS"
if [[ "$prefix" == "pi-hosting/logs/" ]]; then
    case "$MOCK_MODE" in
        aws-error)
            if ((token == 1)); then echo "AccessDenied fixture" >&2; exit 1; fi ;;
        invalid-json) echo '{invalid'; exit 0 ;;
        bad-size) echo '{"IsTruncated":false,"Contents":[{"Size":-1}]}'; exit 0 ;;
        missing-token) echo '{"IsTruncated":true,"Contents":[]}'; exit 0 ;;
        repeated-token) echo '{"IsTruncated":true,"NextContinuationToken":"1"}'; exit 0 ;;
        page-limit)
            jq -n --arg token "$((token + 1))" \
                '{IsTruncated:true,NextContinuationToken:$token,Contents:[]}'
            exit 0 ;;
    esac
    jq -n --argjson page "$token" '{
        IsTruncated: ($page < 11),
        NextContinuationToken: (if $page < 11 then (($page + 1) | tostring) else null end),
        Contents: [range(0;1000) |
            if . % 2 == 0 then {StorageClass:"STANDARD",Size:1024}
            else {StorageClass:"GLACIER_IR",Size:2048} end]
    }'
elif [[ "$prefix" == "pi-hosting/foundry/" ]]; then
    echo '{"IsTruncated":false}'
else
    echo '{"IsTruncated":false,"Contents":[{"Size":1024}]}'
fi
MOCK

cat > "$TEST_DIR/bin/curl" <<'MOCK'
#!/bin/bash
echo '{"rates":{"AUD":1.5}}'
MOCK

cat > "$TEST_DIR/bin/jq" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "${MOCK_MODE:-}" == "state-error" && "$*" == *"--arg report_date"* ]]; then
    echo "State serialization fixture failure" >&2
    exit 1
fi
if [[ "${MOCK_MODE:-}" == "aggregate-error" && "$*" == *"--argjson a"* ]]; then
    echo "Aggregation fixture failure" >&2
    exit 1
fi
exec /usr/bin/jq "$@"
MOCK

cat > "$TEST_DIR/bin/mv" <<'MOCK'
#!/bin/bash
for destination in "$@"; do :; done
if [[ "${MOCK_MODE:-}" == "rename-error" && "$destination" == *"/s3-costs-"????"-"??".json" ]]; then
    echo "State rename fixture failure" >&2
    exit 1
fi
exec /usr/bin/mv "$@"
MOCK

cat > "$STACK/backups/monitoring/scripts/discord-lib.sh" <<'MOCK'
send_discord() {
    if [[ "${EXPECT_SAVE:-true}" == true ]]; then
        jq -e '.services.logs.objects == 12000 and .services.logs.estimated_cost_aud > 0' \
            "$STATE/s3-costs-latest.json" >/dev/null || return 93
    fi
    if [[ "${MOCK_MODE:-}" == "discord-error" ]]; then
        echo "Discord fixture failure" >&2
        return 1
    fi
    echo notified >> "$MOCK_EVENTS"
}
MOCK

cat > "$STACK/backups/monitoring/scripts/backup-status.sh" <<'MOCK'
#!/bin/bash
echo "Heartbeat fixture: exit $MOCK_HEARTBEAT_EXIT"
exit "$MOCK_HEARTBEAT_EXIT"
MOCK
chmod +x "$TEST_DIR/bin/"* "$STACK/backups/monitoring/scripts/backup-status.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); echo "PASS: $*"; }
reset_state() {
    printf '{"original":true}\n' > "$SNAPSHOT"
    ln -sfn "$(basename "$SNAPSHOT")" "$LATEST"
    : > "$MOCK_EVENTS"
    : > "$MOCK_CALLS"
}
assert_original() {
    jq -e '.original == true' "$SNAPSHOT" >/dev/null || fail "Existing state changed"
    [[ "$(readlink "$LATEST")" == "$(basename "$SNAPSHOT")" ]] || fail "Latest pointer changed"
    [[ -z "$(find "$STATE" -maxdepth 1 -name '.s3-costs-*' -print)" ]] || fail "Temporary state leaked"
}
run_report() {
    report_exit=0
    bash "$REPORT" "$@" > "$TEST_DIR/report.log" 2>&1 || report_exit=$?
}

reset_state
export MOCK_MODE=happy EXPECT_SAVE=true
run_report --discord
((report_exit == 0)) || { cat "$TEST_DIR/report.log"; fail "Large report failed"; }
jq -e '
    .total_objects == 12002 and .total_size_bytes == 18434048 and
    .services.logs.objects == 12000 and .services.logs.size_bytes == 18432000 and
    .services.logs.storage_breakdown == [
        {class:"GLACIER_IR",bytes:12288000,objects:6000},
        {class:"STANDARD",bytes:6144000,objects:6000}
    ] and .services.foundry.objects == 0 and
    .services.database.storage_breakdown[0].class == "STANDARD"
' "$LATEST" >/dev/null || fail "Wrong paginated totals or output shape"
[[ "$(grep -c '^pi-hosting/logs/' "$MOCK_CALLS")" == 12 ]] || fail "Wrong page count"
[[ "$(cat "$MOCK_EVENTS")" == notified ]] || fail "Missing notification after save"
[[ "$(stat -c '%a' "$SNAPSHOT")" == 644 ]] || fail "State not readable by monitor"
[[ -z "$(find "$STATE" -maxdepth 1 -name '.s3-costs-*' -print)" ]] || fail "Temporary files leaked"
pass "12,000 objects, mixed classes, empty prefix, pagination and saved-before-notification"

for mode in aws-error invalid-json bad-size missing-token repeated-token aggregate-error page-limit state-error rename-error; do
    reset_state
    export MOCK_MODE="$mode"
    run_report --discord
    ((report_exit != 0)) || fail "$mode unexpectedly succeeded"
    [[ ! -s "$MOCK_EVENTS" ]] || fail "$mode sent a success notification"
    grep -qE 'ERROR|error|failure|AccessDenied' "$TEST_DIR/report.log" || fail "$mode hid the error"
    assert_original
    if [[ "$mode" == page-limit ]]; then
        [[ "$(grep -c '^pi-hosting/logs/' "$MOCK_CALLS")" == 200 ]] || fail "Safety limit not enforced"
    fi
    pass "$mode aborts, preserves prior state and sends no success"
done

reset_state
export MOCK_MODE=happy EXPECT_SAVE=false
run_report --no-save-state --discord
((report_exit == 0)) || fail "--no-save-state failed"
assert_original
[[ "$(cat "$MOCK_EVENTS")" == notified ]] || fail "--no-save-state suppressed Discord"
pass "--no-save-state preserves existing state and allows notification"

reset_state
export MOCK_MODE=discord-error EXPECT_SAVE=true
run_report --discord
((report_exit != 0)) || fail "Discord failure unexpectedly succeeded"
jq -e '.services.logs.objects == 12000' "$LATEST" >/dev/null || fail "Discord failure lost valid state"
! grep -q 'Report complete' "$TEST_DIR/report.log" || fail "Discord failure reported success"
pass "Discord failure remains an error while valid state is retained"

cat > "$TEST_DIR/missing-dependency.sh" <<'MOCK'
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "bc" ]]; then return 1; fi
    builtin command "$@"
}
MOCK
startup_exit=0
BASH_ENV="$TEST_DIR/missing-dependency.sh" \
    bash "$STACK/backups/monitoring/scripts/backup-status-real.sh" heartbeat \
    > "$TEST_DIR/startup.log" 2>&1 || startup_exit=$?
((startup_exit == 2)) || fail "Missing dependency became an accepted warning"
grep -q "Required command 'bc'" "$TEST_DIR/startup.log" || fail "Missing dependency not reported"
pass "Missing heartbeat dependency is a critical error"

startup_exit=0
bash "$STACK/backups/monitoring/scripts/backup-status-real.sh" heartbeat \
    > "$TEST_DIR/startup.log" 2>&1 || startup_exit=$?
((startup_exit == 2)) || fail "Missing library became an accepted warning"
grep -q "Required library" "$TEST_DIR/startup.log" || fail "Missing library not reported"
pass "Missing heartbeat library is a critical error"

mv "$STACK/backups/config.sh" "$STACK/backups/config.saved"
startup_exit=0
bash "$STACK/backups/monitoring/scripts/backup-status-real.sh" heartbeat \
    > "$TEST_DIR/startup.log" 2>&1 || startup_exit=$?
mv "$STACK/backups/config.saved" "$STACK/backups/config.sh"
((startup_exit == 2)) || fail "Missing configuration became an accepted warning"
grep -q 'Failed to load backup configuration' "$TEST_DIR/startup.log" || fail "Missing configuration hidden"
pass "Missing heartbeat configuration is a critical error"

cat > "$TEST_DIR/startup-failure.sh" <<'MOCK'
dirname() { return 1; }
MOCK
startup_exit=0
BASH_ENV="$TEST_DIR/startup-failure.sh" \
    bash "$STACK/backups/monitoring/scripts/backup-status-real.sh" heartbeat \
    > "$TEST_DIR/startup.log" 2>&1 || startup_exit=$?
((startup_exit == 2)) || fail "Unexpected startup failure became an accepted warning"
grep -q 'Heartbeat aborted unexpectedly' "$TEST_DIR/startup.log" || fail "Unexpected failure hidden"
pass "Unexpected heartbeat startup failure is a critical error"

cat > "$TEST_DIR/startup-failure.sh" <<'MOCK'
dirname() { echo "$MISSING_HEARTBEAT_TEST_VARIABLE"; }
MOCK
startup_exit=0
BASH_ENV="$TEST_DIR/startup-failure.sh" \
    bash "$STACK/backups/monitoring/scripts/backup-status-real.sh" heartbeat \
    > "$TEST_DIR/startup.log" 2>&1 || startup_exit=$?
((startup_exit == 2)) || fail "Unbound shell variable became an accepted warning"
grep -q 'unbound variable' "$TEST_DIR/startup.log" || fail "Fatal shell failure hidden"
pass "Fatal heartbeat shell errors are not accepted warnings"

for code in 0 1 2 126; do
    export MOCK_HEARTBEAT_EXIT="$code"
    wrapper_exit=0
    bash "$STACK/backups/monitoring/heartbeat/heartbeat-wrapper.sh" \
        > "$TEST_DIR/wrapper.log" 2>&1 || wrapper_exit=$?
    ((wrapper_exit == code)) || fail "Heartbeat code $code became $wrapper_exit"
    if ((code == 1)); then
        grep -q 'completed with warnings' "$TEST_DIR/wrapper.log" || fail "Warning logged as failure"
        ! grep -q 'failed with exit code' "$TEST_DIR/wrapper.log" || fail "Warning logged as failure"
    elif ((code != 0)); then
        grep -q "failed with exit code $code" "$TEST_DIR/wrapper.log" || fail "Error hidden"
    fi
    pass "Heartbeat preserves exit code $code with correct severity"
done

generic_exit=0
(
    source "$STACK/backups/lib/wrapper-lib.sh"
    setup_wrapper "$TEST_DIR/generic-logs" generic
    run_with_logging "Ordinary Backup" bash -c 'exit 1'
) > "$TEST_DIR/generic.log" 2>&1 || generic_exit=$?
((generic_exit == 1)) || fail "Ordinary backup failure was suppressed"
grep -q 'failed with exit code 1' "$TEST_DIR/generic.log" || fail "Ordinary failure became warning"
grep -qx 'SuccessExitStatus=1' "$ROOT_DIR/backups/monitoring/heartbeat/backup-heartbeat.service" \
    || fail "Heartbeat unit does not accept warning code"
pass "Ordinary backup failures unchanged; heartbeat unit accepts warnings only"

echo "All $passed monitoring regression checks passed."
