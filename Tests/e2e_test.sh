#!/bin/bash
# Cyclop One E2E Test Harness
# Sprint 10: Automated end-to-end testing
#
# Usage: ./Tests/e2e_test.sh [--api-key KEY] [--test TESTNAME] [--skip-build]
#
# Tests:
#   calculator  - Open Calculator, type 123+456=, verify result
#   textedit    - Open TextEdit, type a sentence, verify text appeared
#   chrome      - Open a URL in Chrome, verify page loaded
#   all         - Run all tests (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="/Applications/CyclopOne.app"
BINARY_PATH="$APP_PATH/Contents/MacOS/Cyclop One"
LOG_FILE="/tmp/cyclopone_e2e_$(date +%Y%m%d_%H%M%S).log"
STDOUT_LOG="/tmp/cyclopone_stdout.log"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/CyclopOne"
SEND_CMD="/tmp/send_command"
RESULTS_FILE="/tmp/cyclopone_e2e_results.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
API_KEY="${CYCLOP_ONE_API_KEY:-}"
TEST_NAME="all"
SKIP_BUILD=false
TIMEOUT=180  # seconds per test

while [[ $# -gt 0 ]]; do
    case $1 in
        --api-key) API_KEY="$2"; shift 2 ;;
        --test) TEST_NAME="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$API_KEY" ]]; then
    echo -e "${RED}Error: API key required. Set CYCLOP_ONE_API_KEY or use --api-key${NC}"
    exit 1
fi

# Logging
log() { echo -e "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"; }
pass() { log "${GREEN}PASS${NC}: $1"; }
fail() { log "${RED}FAIL${NC}: $1"; }
info() { log "${YELLOW}INFO${NC}: $1"; }

# Initialize results
echo '{"tests":[],"startTime":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$RESULTS_FILE"

record_result() {
    local name="$1" status="$2" duration="$3" iterations="$4" detail="$5"
    # Use python3 for JSON manipulation (available on macOS)
    python3 -c "
import json, sys
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
data['tests'].append({
    'name': '$name',
    'status': '$status',
    'duration_s': $duration,
    'iterations': $iterations,
    'detail': '$detail'
})
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
}

# Step 1: Build
if [[ "$SKIP_BUILD" == false ]]; then
    info "Building CyclopOne..."
    cd "$PROJECT_DIR"
    if xcodebuild -scheme CyclopOne -configuration Debug \
        -derivedDataPath "$DERIVED_DATA" build 2>&1 | tee -a "$LOG_FILE" | tail -5 | grep -q "BUILD SUCCEEDED"; then
        pass "Build succeeded"
    else
        fail "Build failed"
        exit 1
    fi
else
    info "Skipping build (--skip-build)"
fi

# Step 2: Deploy
info "Deploying to $APP_PATH..."
pkill -f "Cyclop One" 2>/dev/null || true
sleep 2
security delete-generic-password -s "com.cyclop.one.apikey" 2>/dev/null || true

# Clean incomplete journals
find "$HOME/Library/Application Support/CyclopOne" -name "*.journal.jsonl" 2>/dev/null | while read f; do
    if ! grep -q '"run.complete"\|"run.fail"\|"run.cancel"' "$f" 2>/dev/null; then
        echo '{"type":"run.fail","reason":"Orphaned by E2E test","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$f"
    fi
done

rm -rf "$APP_PATH"
cp -R "$DERIVED_DATA/Build/Products/Debug/Cyclop One.app" "$APP_PATH"
pass "Deployed"

# Step 3: Launch
info "Launching CyclopOne..."
caffeinate -dis "$BINARY_PATH" > "$STDOUT_LOG" 2>&1 &
APP_PID=$!
sleep 4

if ! kill -0 $APP_PID 2>/dev/null; then
    fail "App failed to start"
    tail -20 "$STDOUT_LOG"
    exit 1
fi
pass "App launched (PID $APP_PID)"

# Step 4: Set API key
info "Setting API key..."
"$SEND_CMD" setkey "$API_KEY"
sleep 2
pass "API key set"

# Step 5: Run tests

wait_for_completion() {
    local timeout=$1
    local start=$(date +%s)
    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start))
        if [[ $elapsed -ge $timeout ]]; then
            echo "TIMEOUT"
            return 1
        fi

        # Check if a run completed by looking at recent log output
        if tail -50 "$STDOUT_LOG" | grep -q "run complete\|Run ended\|score=\|RunResult\|verification.*score\|Completed (score" 2>/dev/null; then
            echo "$elapsed"
            return 0
        fi

        # Check if app is still running
        if ! kill -0 $APP_PID 2>/dev/null; then
            echo "CRASHED"
            return 1
        fi

        sleep 3
    done
}

extract_score() {
    # Extract the verification score from recent logs
    tail -100 "$STDOUT_LOG" | grep -oE "score=[0-9]+" | tail -1 | grep -oE "[0-9]+" || echo "0"
}

extract_iterations() {
    # Extract iteration count from recent logs
    tail -100 "$STDOUT_LOG" | grep -oE "iterations=[0-9]+" | tail -1 | grep -oE "[0-9]+" || echo "0"
}

run_test() {
    local name="$1"
    local command="$2"
    local min_score="${3:-60}"

    info "--- Test: $name ---"
    info "Command: $command"

    # Clear log marker
    echo "=== E2E TEST START: $name ===" >> "$STDOUT_LOG"

    local start_time=$(date +%s)
    "$SEND_CMD" run "$command"

    local duration
    duration=$(wait_for_completion "$TIMEOUT")
    local status=$?

    if [[ $status -ne 0 ]]; then
        local end_time=$(date +%s)
        duration=$((end_time - start_time))
        fail "$name — $duration (timeout or crash)"
        record_result "$name" "fail" "$duration" "0" "timeout_or_crash"
        return 1
    fi

    local score=$(extract_score)
    local iterations=$(extract_iterations)

    info "Score: $score, Iterations: $iterations, Duration: ${duration}s"

    if [[ "$score" -ge "$min_score" ]]; then
        pass "$name — score=$score, iter=$iterations, ${duration}s"
        record_result "$name" "pass" "$duration" "$iterations" "score_$score"
        return 0
    else
        fail "$name — score=$score < $min_score, iter=$iterations, ${duration}s"
        record_result "$name" "fail" "$duration" "$iterations" "score_$score"
        return 1
    fi
}

# Test definitions
PASS_COUNT=0
FAIL_COUNT=0

run_and_count() {
    if run_test "$@"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    # Wait between tests for app to settle
    sleep 5
}

case "$TEST_NAME" in
    calculator)
        run_and_count "calculator" "open Calculator and type 123+456 then press equals" 70
        ;;
    textedit)
        run_and_count "textedit" "open TextEdit, create a new document, and type Hello World" 60
        ;;
    chrome)
        run_and_count "chrome" "open Chrome and navigate to example.com" 60
        ;;
    all)
        run_and_count "calculator" "open Calculator and type 123+456 then press equals" 70
        run_and_count "textedit" "open TextEdit, create a new document, and type Hello World" 60
        run_and_count "chrome" "open Chrome and navigate to example.com" 60
        ;;
    *)
        fail "Unknown test: $TEST_NAME"
        exit 1
        ;;
esac

# Step 6: Results summary
echo ""
info "========================================="
info "E2E Test Results"
info "========================================="
info "Passed: $PASS_COUNT"
info "Failed: $FAIL_COUNT"
info "Total:  $((PASS_COUNT + FAIL_COUNT))"
info "Results: $RESULTS_FILE"
info "Logs:    $LOG_FILE"
info "App log: $STDOUT_LOG"
info "========================================="

# Add summary to results
python3 -c "
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
data['summary'] = {
    'passed': $PASS_COUNT,
    'failed': $FAIL_COUNT,
    'total': $((PASS_COUNT + FAIL_COUNT))
}
data['endTime'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

# Cleanup
info "Stopping CyclopOne..."
pkill -f "Cyclop One" 2>/dev/null || true

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
