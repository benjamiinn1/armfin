# CLAUDE.md

## Project
**armfin** — free, open-source, standalone watchOS app. Streams and downloads music from a personal Jellyfin server. No iPhone, no companion app, no cloud intermediary. See `documentation/business_description.md` for the full pitch.

## Read first
- **`.claude/memory.md`** — build log & milestone tracker. Check what's done, what's next.
- **`.claude/rules/soul.md`** — engineering guardrails. Memory discipline, CPU idle rules, zero heavy animation. Review before marking any task done.
- **`specs/spec.md`** — technical spec. Architecture, Jellyfin API, SwiftData schema, playback engine, UI map.

## Structure & Deployment
- Xcode project: `armfin/armfin.xcodeproj` (lives one level below repo root).
- Two targets:
  - **`armfin Watch App`** — the real app. All source at `armfin/armfin Watch App/`. Xcode 16 file-system-synchronized groups: create files/folders on disk, they auto-register.
  - **`armfin`** — thin App Store packaging container. No source. Never add code to it.
- Deployment target: watchOS 26+, Swift 6, strict concurrency.

## Engineering Philosophy
Single watchOS target only. SwiftUI + SwiftData + AVFoundation. Pure black UI (`#000000`), no heavy animation. Extreme discipline on memory/CPU/battery (see `.claude/rules/soul.md`).

## Development Workflow — SDMA Loop (Planner / Researcher / Developer / Tester)
For substantive feature work (not typo fixes or doc edits), run the spec-driven multi-agent loop using the four personas in `.claude/agents/`:

1. **`planner`** — reads spec.md + memory.md, decomposes into one scoped node with hardened binary acceptance criteria. Never writes code. Single point of contact with the user.
2. **`researcher`** — grounds criteria in current platform reality (watchOS 26, Swift 6, Jellyfin API). Finds idiomatic patterns, internal code to reuse, and anti-patterns to avoid. Never writes feature code.
3. **`developer`** — implements exactly the hardened brief under `armfin/armfin Watch App/`. Never runs the build, never grades itself.
4. **`tester`** — runs `xcodebuild` against the real scheme (`armfin Watch App`) plus a `soul.md` guardrail scan, returns PASS/FAIL with evidence. Never edits source code.

**The loop:**
- Planner + Researcher + Tester harden the spec together (before code exists).
- Developer builds to the hardened criteria.
- Tester executes adversarially — build, guardrail scan, technique catalog (EP, BVA, INV, NEG, SDC).
- On FAIL: hand the Tester's report back to `developer` for a fix, or to `planner` if the approach itself was wrong — don't just retry blindly.
- On PASS: Planner validates against criteria (second look), then appends a Build Log entry to `.claude/memory.md` and checks off the roadmap item. Loop back to `planner` for the next node.

This loop is for milestone-sized feature work with clear acceptance criteria. For small, single-file, or exploratory changes, just do the work directly — spinning up four personas for a one-line fix is pure overhead.
