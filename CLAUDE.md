# Intertrust

> See `AGENTS.md` for full development guide.

## Overview

Agent trust scoring engine — tracks reputation based on finding acceptance/rejection, computes severity-weighted time-decayed trust scores, and identifies suppression candidates. Extracted from Interspect to maintain single-responsibility.

## Quick Commands

```bash
bash -n hooks/lib-trust.sh             # Syntax check
bash tests/test_trust_scoring.sh       # Run 11 tests
python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"  # Manifest check
```

## Architecture

Trust data lives in the shared `.interspect/interspect.db` (trust_feedback table). The library is self-contained — it creates the table if missing but doesn't manage other interspect tables.

**Score algorithm:** Time-decayed (30-day half-life), severity-weighted (P0=4x, P3=0.5x), project/global blended (blend weight = min(1.0, project_reviews/20)), floored at 0.05, capped at 1.0.

## Integration Points

- **interflux/launch.md Step 2.1e** — sources lib-trust.sh, calls `_trust_scores_batch()` to apply trust multiplier on agent dispatch
- **clavain/resolve.md** — sources lib-trust.sh, calls `_trust_record_outcome()` when findings are fixed or dismissed
- Both consumers discover the library via `find ~/.claude/plugins/cache -path "*/intertrust/*/hooks/lib-trust.sh"`

## Design Decisions (Do Not Re-Ask)

- Self-contained library (no dependency on lib-interspect.sh)
- Shared DB with interspect (trust_feedback table in interspect.db)
- `_interspect_project_name` shim provided for backward compatibility
- All operations fail-open (return neutral 1.0 on any error)
- Trust is progressive enhancement — never a gate
