#!/usr/bin/env bash
# lib-trust.sh — Trust scoring engine for agent reputation.
#
# Extracted from interspect into standalone intertrust plugin.
# Self-contained: DB access functions inlined (no dependency on lib-interspect.sh).
#
# Usage:
#   source hooks/lib-trust.sh
#   _trust_record_outcome "$session_id" "fd-safety" "my-project" "P1-1" "P1" "accepted" "run-123"
#   score=$(_trust_score "fd-safety" "my-project")
#   _trust_report  # table of all scores
#
# Provides:
#   _trust_record_outcome   — record accept/discard for a finding
#   _trust_score            — compute trust for (agent, project) pair
#   _trust_scores_batch     — batch-load trust for all agents in a project
#   _trust_report           — formatted table of all trust data
#   _trust_severity_weight  — severity → numeric weight

[[ -n "${_LIB_TRUST_LOADED:-}" ]] && return 0
_LIB_TRUST_LOADED=1

# ─── DB access (inlined from lib-interspect.sh) ──────────────────────────────

# Returns the path to the interspect SQLite database.
# Trust data lives in the same DB as interspect evidence — shared schema.
_trust_db_path() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    echo "${root}/.interspect/interspect.db"
}

# Returns the project name (basename of repo root).
_trust_project_name() {
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# Ensure the trust_feedback table exists in the shared interspect DB.
# Creates the DB directory + table if needed. Sets _TRUST_DB global.
_trust_ensure_db() {
    _TRUST_DB=$(_trust_db_path)

    if [[ -f "$_TRUST_DB" ]]; then
        # DB exists (interspect created it) — ensure trust table via migration
        sqlite3 "$_TRUST_DB" <<'MIGRATE'
CREATE TABLE IF NOT EXISTS trust_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent TEXT NOT NULL,
    project TEXT NOT NULL,
    finding_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    outcome TEXT NOT NULL,
    review_run_id TEXT,
    weight REAL NOT NULL DEFAULT 1.0
);
CREATE INDEX IF NOT EXISTS idx_trust_agent_project ON trust_feedback(agent, project);
CREATE INDEX IF NOT EXISTS idx_trust_ts ON trust_feedback(ts);
CREATE INDEX IF NOT EXISTS idx_trust_outcome ON trust_feedback(outcome);
MIGRATE
        return 0
    fi

    # DB doesn't exist yet — create directory + minimal schema
    mkdir -p "$(dirname "$_TRUST_DB")" 2>/dev/null || return 1

    sqlite3 "$_TRUST_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS trust_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent TEXT NOT NULL,
    project TEXT NOT NULL,
    finding_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    outcome TEXT NOT NULL,
    review_run_id TEXT,
    weight REAL NOT NULL DEFAULT 1.0
);
CREATE INDEX IF NOT EXISTS idx_trust_agent_project ON trust_feedback(agent, project);
CREATE INDEX IF NOT EXISTS idx_trust_ts ON trust_feedback(ts);
CREATE INDEX IF NOT EXISTS idx_trust_outcome ON trust_feedback(outcome);
SQL
}

# Sanitize a string for safe DB storage.
# Pipeline: strip ANSI → strip control chars → truncate → redact secrets → reject injection.
_trust_sanitize() {
    local input="$1"
    local max_chars="${2:-500}"

    # 1. Strip ANSI escape sequences
    input=$(printf '%s' "$input" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

    # 2. Strip control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F)
    input=$(printf '%s' "$input" | tr -d '\000-\010\013-\014\016-\037')

    # 3. Truncate to max_chars
    input="${input:0:$max_chars}"

    # 4. Redact secrets
    input=$(_trust_redact_secrets "$input")

    # 5. Reject instruction-like patterns (case-insensitive)
    local lower="${input,,}"
    if [[ "$lower" == *"<system>"* ]] || \
       [[ "$lower" == *"<instructions>"* ]] || \
       [[ "$lower" == *"ignore previous"* ]] || \
       [[ "$lower" == *"you are now"* ]] || \
       [[ "$lower" == *"disregard"* ]] || \
       [[ "$lower" == *"system:"* ]]; then
        return 1
    fi

    printf '%s' "$input"
}

# Redact common secret patterns from a string.
_trust_redact_secrets() {
    local input="$1"
    [[ -z "$input" ]] && return 0

    local result="$input"

    # API keys
    result=$(printf '%s' "$result" | sed -E 's/(api[_-]?key|apikey|api[_-]?secret)[[:space:]]*[:=][[:space:]]*['"'"'"][^'"'"'"]{8,}['"'"'"]/\1=[REDACTED:api_key]/gi') || true
    # Bearer/token auth
    result=$(printf '%s' "$result" | sed -E 's/(bearer|token|auth)[[:space:]]+[A-Za-z0-9_\.\-]{20,}/\1 [REDACTED:token]/gi') || true
    # AWS keys
    result=$(printf '%s' "$result" | sed -E 's/AKIA[0-9A-Z]{16}/[REDACTED:aws_key]/g') || true
    # GitHub tokens
    result=$(printf '%s' "$result" | sed -E 's/gh[ps]_[A-Za-z0-9]{36,}/[REDACTED:github_token]/g') || true
    result=$(printf '%s' "$result" | sed -E 's/github_pat_[A-Za-z0-9_]{22,}/[REDACTED:github_token]/g') || true
    # Anthropic keys
    result=$(printf '%s' "$result" | sed -E 's/sk-ant-[A-Za-z0-9\-]{20,}/[REDACTED:anthropic_key]/g') || true
    # OpenAI keys
    result=$(printf '%s' "$result" | sed -E 's/sk-[A-Za-z0-9]{20,}/[REDACTED:openai_key]/g') || true
    # Connection strings
    result=$(printf '%s' "$result" | sed -E 's|[a-zA-Z]+://[^:]+:[^@]+@[^/[:space:]]+|[REDACTED:connection_string]|g') || true
    # Generic password patterns
    result=$(printf '%s' "$result" | sed -E 's/(password|passwd|pwd|secret)[[:space:]]*[:=][[:space:]]*['"'"'"][^'"'"'"]{4,}['"'"'"]/\1=[REDACTED:password]/gi') || true

    printf '%s' "$result"
}

# ─── Backward compatibility shims ─────────────────────────────────────────────
# External consumers (interflux launch.md, clavain resolve.md) call the original
# _interspect_* names. Provide shims so existing code works with either plugin.

_interspect_project_name() { _trust_project_name "$@"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Severity weights: P0=4x, P1=2x, P2=1x, P3=0.5x
_trust_severity_weight() {
    case "${1:-P2}" in
        P0|p0) echo "4.0" ;;
        P1|p1) echo "2.0" ;;
        P2|p2) echo "1.0" ;;
        P3|p3) echo "0.5" ;;
        *)     echo "1.0" ;;
    esac
}

# ─── Evidence recording ──────────────────────────────────────────────────────

# Record a finding outcome (accepted or discarded).
# Args: session_id agent project finding_id severity outcome [review_run_id]
# outcome: "accepted" or "discarded"
# Fails silently — never blocks workflow.
_trust_record_outcome() {
    local session_id="${1:?session_id required}"
    local agent="${2:?agent required}"
    local project="${3:?project required}"
    local finding_id="${4:?finding_id required}"
    local severity="${5:?severity required}"
    local outcome="${6:?outcome required}"
    local review_run_id="${7:-}"

    _trust_ensure_db || return 0
    local weight
    weight=$(_trust_severity_weight "$severity")

    # Sanitize inputs
    agent=$(_trust_sanitize "$agent" 100) || return 0
    project=$(_trust_sanitize "$project" 200) || return 0
    finding_id=$(_trust_sanitize "$finding_id" 100) || return 0
    severity=$(_trust_sanitize "$severity" 10) || return 0
    outcome=$(_trust_sanitize "$outcome" 20) || return 0

    # Validate outcome
    case "$outcome" in
        accepted|discarded) ;;
        *) return 0 ;;
    esac

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    sqlite3 "$_TRUST_DB" "INSERT INTO trust_feedback
        (ts, session_id, agent, project, finding_id, severity, outcome, review_run_id, weight)
        VALUES
        ('$ts', '${session_id//\'/\'\'}', '${agent//\'/\'\'}', '${project//\'/\'\'}',
         '${finding_id//\'/\'\'}', '${severity//\'/\'\'}', '${outcome//\'/\'\'}',
         '${review_run_id//\'/\'\'}', $weight);" 2>/dev/null || true
}

# ─── Score computation ────────────────────────────────────────────────────────

# Compute trust score for an (agent, project) pair.
# Returns float 0.05-1.0 on stdout. Returns 1.0 if no data.
# Uses approximate decay (half-life ~30 days) and blends project/global scores.
_trust_score() {
    local agent="${1:?agent required}"
    local project="${2:?project required}"

    _trust_ensure_db || { echo "1.0"; return 0; }

    # Decay approximation: weight * 1/(1 + days_old/30)
    # This gives: 0 days=1.0, 30 days=0.5, 60 days=0.33, 90 days=0.25

    # Project-specific score
    local project_result
    project_result=$(sqlite3 "$_TRUST_DB" "
        SELECT
            COALESCE(SUM(CASE WHEN outcome='accepted' THEN weight * (1.0 / (1.0 + (julianday('now') - julianday(ts)) / 30.0)) ELSE 0 END), 0),
            COALESCE(SUM(weight * (1.0 / (1.0 + (julianday('now') - julianday(ts)) / 30.0))), 0),
            COUNT(*)
        FROM trust_feedback
        WHERE agent='${agent//\'/\'\'}' AND project='${project//\'/\'\'}';
    " 2>/dev/null) || { echo "1.0"; return 0; }

    local project_accepted project_total project_count
    project_accepted=$(echo "$project_result" | cut -d'|' -f1)
    project_total=$(echo "$project_result" | cut -d'|' -f2)
    project_count=$(echo "$project_result" | cut -d'|' -f3)

    # Global score (all projects for this agent)
    local global_result
    global_result=$(sqlite3 "$_TRUST_DB" "
        SELECT
            COALESCE(SUM(CASE WHEN outcome='accepted' THEN weight * (1.0 / (1.0 + (julianday('now') - julianday(ts)) / 30.0)) ELSE 0 END), 0),
            COALESCE(SUM(weight * (1.0 / (1.0 + (julianday('now') - julianday(ts)) / 30.0))), 0),
            COUNT(*)
        FROM trust_feedback
        WHERE agent='${agent//\'/\'\'}';
    " 2>/dev/null) || { echo "1.0"; return 0; }

    local global_accepted global_total global_count
    global_accepted=$(echo "$global_result" | cut -d'|' -f1)
    global_total=$(echo "$global_result" | cut -d'|' -f2)
    global_count=$(echo "$global_result" | cut -d'|' -f3)

    # No data at all → neutral trust
    if [[ "$global_count" -eq 0 ]]; then
        echo "1.0"
        return 0
    fi

    # Compute blended score via awk (floating point)
    awk -v pa="$project_accepted" -v pt="$project_total" -v pc="$project_count" \
        -v ga="$global_accepted" -v gt="$global_total" \
        'BEGIN {
        # Global score
        global_score = (gt > 0) ? ga / gt : 1.0

        # Project score (falls back to global if no project data)
        project_score = (pt > 0) ? pa / pt : global_score

        # Blend weight: min(1.0, project_reviews / 20)
        w = pc / 20.0
        if (w > 1.0) w = 1.0

        # Blended score
        trust = (w * project_score) + ((1.0 - w) * global_score)

        # Floor at 0.05
        if (trust < 0.05) trust = 0.05
        # Cap at 1.0
        if (trust > 1.0) trust = 1.0

        printf "%.2f\n", trust
    }'
}

# Batch-load trust scores for all known agents in a project.
# Output: agent\ttrust_score (one per line). Used by triage to avoid N queries.
_trust_scores_batch() {
    local project="${1:?project required}"

    _trust_ensure_db || return 0

    local agents
    agents=$(sqlite3 "$_TRUST_DB" "
        SELECT DISTINCT agent FROM trust_feedback;
    " 2>/dev/null) || return 0

    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        local score
        score=$(_trust_score "$agent" "$project")
        printf "%s\t%s\n" "$agent" "$score"
    done <<< "$agents"
}

# ─── Observability ────────────────────────────────────────────────────────────

# Report trust scores for all agents across all projects.
# Output: formatted table for debugging.
_trust_report() {
    _trust_ensure_db || { echo "No interspect DB found"; return 0; }

    printf "%-20s %-20s %6s %8s %8s %10s\n" "AGENT" "PROJECT" "TRUST" "ACCEPTED" "DISCARD" "REVIEWS"
    printf "%-20s %-20s %6s %8s %8s %10s\n" "----" "----" "----" "----" "----" "----"

    # Per-project scores
    local rows
    rows=$(sqlite3 "$_TRUST_DB" "
        SELECT agent, project,
            SUM(CASE WHEN outcome='accepted' THEN 1 ELSE 0 END),
            SUM(CASE WHEN outcome='discarded' THEN 1 ELSE 0 END),
            COUNT(*)
        FROM trust_feedback
        GROUP BY agent, project
        ORDER BY agent, project;
    " 2>/dev/null) || return 0

    while IFS='|' read -r agent project accepted discarded total; do
        [[ -z "$agent" ]] && continue
        local score
        score=$(_trust_score "$agent" "$project")
        local marker=""
        if awk -v s="$score" 'BEGIN { exit !(s < 0.30) }' 2>/dev/null; then
            marker=" <!>"
        fi
        printf "%-20s %-20s %6s %8s %8s %10s%s\n" "$agent" "$project" "$score" "$accepted" "$discarded" "$total" "$marker"
    done <<< "$rows"

    # Global summary
    echo ""
    echo "Global averages:"
    local global_rows
    global_rows=$(sqlite3 "$_TRUST_DB" "
        SELECT agent,
            SUM(CASE WHEN outcome='accepted' THEN 1 ELSE 0 END),
            SUM(CASE WHEN outcome='discarded' THEN 1 ELSE 0 END),
            COUNT(*)
        FROM trust_feedback
        GROUP BY agent
        ORDER BY agent;
    " 2>/dev/null) || return 0

    while IFS='|' read -r agent accepted discarded total; do
        [[ -z "$agent" ]] && continue
        local ratio="N/A"
        if [[ "$total" -gt 0 ]]; then
            ratio=$(awk -v a="$accepted" -v t="$total" 'BEGIN { printf "%.0f%%", (a/t)*100 }')
        fi
        printf "  %-20s %s accepted (%s/%s)\n" "$agent" "$ratio" "$accepted" "$total"
    done <<< "$global_rows"
}
