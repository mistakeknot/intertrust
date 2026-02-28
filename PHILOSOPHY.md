# intertrust Philosophy

## Purpose
Agent trust scoring — severity-weighted time-decayed reputation tracking. Records finding acceptance/rejection, computes blended project/global trust scores, identifies suppression candidates.

## North Star
Maximize trust signal accuracy — every score should predict future agent quality.

## Working Priorities
- Score calibration (predicted vs actual quality)
- Decay correctness (stale trust fades)
- Suppression precision (suppress bad agents, never good ones)

## Brainstorming Doctrine
1. Start from outcomes and failure modes, not implementation details.
2. Generate at least three options: conservative, balanced, and aggressive.
3. Explicitly call out assumptions, unknowns, and dependency risk across modules.
4. Prefer ideas that improve clarity, reversibility, and operational visibility.

## Planning Doctrine
1. Convert selected direction into small, testable, reversible slices.
2. Define acceptance criteria, verification steps, and rollback path for each slice.
3. Sequence dependencies explicitly and keep integration contracts narrow.
4. Reserve optimization work until correctness and reliability are proven.

## Decision Filters
- Does this make trust scores more predictive?
- Does this prevent gaming or feedback loops?
- Is the scoring transparent and auditable?
- Can we recover from a miscalibrated score?
