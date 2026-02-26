#!/usr/bin/env bash
# test_trust_scoring.sh — End-to-end test for trust scoring pipeline.
# Creates a temp DB, records mock outcomes, verifies score computation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../hooks"

# Create temp directory with git init (required for _trust_project_name)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"
git init -q

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (expected=$expected actual=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_range() {
    local label="$1" min="$2" max="$3" actual="$4"
    if awk -v a="$actual" -v lo="$min" -v hi="$max" 'BEGIN { exit !(a >= lo && a <= hi) }'; then
        echo "PASS: $label ($actual in [$min, $max])"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label ($actual not in [$min, $max])"
        FAIL=$((FAIL + 1))
    fi
}

# Source library (override DB path via function redefinition)
source "$LIB_DIR/lib-trust.sh"

# Override DB path to temp dir
_trust_db_path() { echo "$TMPDIR/.interspect/interspect.db"; }

_trust_ensure_db

echo "=== Trust Scoring Tests ==="
echo ""

# Test 1: No data → trust = 1.0
score=$(_trust_score "fd-safety" "test-project")
assert_eq "No data returns 1.0" "1.0" "$score"

# Test 2: All accepted → high trust
for i in $(seq 1 10); do
    _trust_record_outcome "sess-1" "fd-safety" "test-project" "finding-$i" "P1" "accepted" "run-1"
done
score=$(_trust_score "fd-safety" "test-project")
assert_range "All accepted → high trust" "0.80" "1.00" "$score"

# Test 3: All discarded → low trust (but above floor)
for i in $(seq 1 10); do
    _trust_record_outcome "sess-2" "fd-game-design" "test-project" "finding-$i" "P2" "discarded" "run-2"
done
score=$(_trust_score "fd-game-design" "test-project")
assert_range "All discarded → low trust (above 0.05 floor)" "0.05" "0.20" "$score"

# Test 4: Mixed outcomes → intermediate trust
for i in $(seq 1 5); do
    _trust_record_outcome "sess-3" "fd-quality" "test-project" "finding-a$i" "P2" "accepted" "run-3"
done
for i in $(seq 1 5); do
    _trust_record_outcome "sess-3" "fd-quality" "test-project" "finding-d$i" "P2" "discarded" "run-3"
done
score=$(_trust_score "fd-quality" "test-project")
assert_range "50/50 → ~0.50 trust" "0.40" "0.60" "$score"

# Test 5: Severity weighting — P0 accepted counts more than P3 discarded
for i in $(seq 1 3); do
    _trust_record_outcome "sess-4" "fd-correctness" "test-project" "p0-$i" "P0" "accepted" "run-4"
done
for i in $(seq 1 10); do
    _trust_record_outcome "sess-4" "fd-correctness" "test-project" "p3-$i" "P3" "discarded" "run-4"
done
score=$(_trust_score "fd-correctness" "test-project")
assert_range "P0 accepted outweighs P3 discarded" "0.55" "0.85" "$score"

# Test 6: Global fallback for new project
# fd-safety has data on test-project but not new-project
score=$(_trust_score "fd-safety" "new-project")
assert_range "New project inherits global score" "0.80" "1.00" "$score"

# Test 7: Batch loading returns all agents with data
batch=$(_trust_scores_batch "test-project")
agents_count=$(echo "$batch" | grep -c $'\t' || echo 0)
assert_range "Batch loads multiple agents" "3" "10" "$agents_count"

# Test 8: Report runs without error and has content
output=$(_trust_report 2>&1)
line_count=$(echo "$output" | wc -l)
assert_range "Report has content" "5" "999" "$line_count"

# Test 9: Floor enforcement — score never below 0.05
for i in $(seq 1 50); do
    _trust_record_outcome "sess-5" "fd-terrible" "test-project" "bad-$i" "P0" "discarded" "run-5"
done
score=$(_trust_score "fd-terrible" "test-project")
assert_range "Floor enforced at 0.05" "0.05" "0.06" "$score"

# Test 10: Invalid outcome is silently ignored
before=$(sqlite3 "$_TRUST_DB" "SELECT COUNT(*) FROM trust_feedback;" 2>/dev/null)
_trust_record_outcome "sess-6" "fd-safety" "test-project" "f-1" "P1" "invalid_outcome" "run-6"
after=$(sqlite3 "$_TRUST_DB" "SELECT COUNT(*) FROM trust_feedback;" 2>/dev/null)
assert_eq "Invalid outcome ignored" "$before" "$after"

# Test 11: Backward compat shim — _interspect_project_name works
project=$(_interspect_project_name)
assert_eq "Backward compat shim works" "$(basename "$TMPDIR")" "$project"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
