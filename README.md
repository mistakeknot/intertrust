# intertrust

Agent trust scoring for Claude Code. Tracks which review agents produce useful findings and which waste tokens.

## What this does

When interflux dispatches review agents, some consistently produce findings you act on — and some produce noise you dismiss. Intertrust closes the feedback loop: it records each accept/dismiss decision, computes a trust score per agent, and feeds that score back into dispatch priority so the good agents run first and the noisy ones get deprioritized.

The scoring algorithm uses severity-weighted time decay: a P0 finding accepted yesterday counts more than a P3 finding dismissed last month. Scores blend project-specific data with global data, so a new project inherits the agent's cross-project reputation until enough local data accumulates.

Intertrust was extracted from the [interspect](https://github.com/mistakeknot/interspect) profiler to maintain single-responsibility: interspect handles evidence collection and routing overrides; intertrust handles reputation and trust.

## Install

First, add the [interagency marketplace](https://github.com/mistakeknot/interagency-marketplace) (one-time setup):

```bash
/plugin marketplace add mistakeknot/interagency-marketplace
```

Then install:

```bash
/plugin install intertrust
```

## Usage

Check which agents are earning trust and which are candidates for suppression:

```
/trust-status
```

```
AGENT                PROJECT              TRUST ACCEPTED  DISCARD    REVIEWS
fd-safety            my-project            0.92        18        2         20
fd-correctness       my-project            0.85        12        3         15
fd-game-design       my-project            0.15         1       12         13 <!>
```

Agents with trust < 0.30 are flagged with `<!>` as suppression candidates. These agents consistently produce findings that nobody acts on.

For a specific agent:

```
/trust-status fd-safety
```

## How trust scores work

**Score range:** 0.05 (floor) to 1.0 (ceiling).

**Inputs:** Every time you resolve a review finding (via `/clavain:resolve`), the outcome is recorded:
- **Accepted** — you fixed the code to address the finding
- **Discarded** — you dismissed it as irrelevant or incorrect

**Severity weighting:** A P0 finding counts 4x, P1 counts 2x, P2 counts 1x, P3 counts 0.5x. Catching a real security issue (P0, accepted) boosts trust much more than flagging a style nit (P3, accepted).

**Time decay:** Half-life of ~30 days. Recent outcomes matter more than old ones. An agent that improved its prompts last week shouldn't be penalized for noise it generated two months ago.

**Project/global blending:** New projects inherit the agent's global reputation until enough local data accumulates (blend weight reaches 1.0 at 20 local reviews).

**Integration:** [interflux](https://github.com/mistakeknot/interflux) multiplies each agent's triage score by its trust score at dispatch time. High-trust agents get dispatched first. Low-trust agents may not get dispatched at all if the token budget is tight.

## Disabling

Trust scoring is progressive enhancement — it never blocks workflows. If intertrust is not installed, all agents get a neutral trust score of 1.0.

## Architecture

Trust data lives in the shared `.interspect/interspect.db` SQLite database (the `trust_feedback` table). The library is self-contained with no dependency on the interspect plugin — it creates its own table if needed.

```
intertrust/
├── .claude-plugin/plugin.json    # Plugin manifest
├── hooks/
│   └── lib-trust.sh              # Trust scoring library (233 lines)
├── commands/
│   └── trust-status.md           # /trust-status command
└── tests/
    └── test_trust_scoring.sh     # 11 tests
```

## Related

- [interspect](https://github.com/mistakeknot/interspect) — agent profiler (evidence, routing, canaries)
- [interflux](https://github.com/mistakeknot/interflux) — multi-agent review engine (the primary trust consumer)
- [Clavain](https://github.com/mistakeknot/Clavain) — the orchestrator whose resolve command feeds trust data
