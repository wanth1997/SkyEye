# Trading mobile summary implementation plan

> **For agentic workers:** Use executing-plans in this dedicated worktree.

**Goal:** Keep all ten statuses in one monitoring summary and make its mobile labels and values readable.

**Architecture:** Use Grafana 11.2's native Stat auto grid with enough height, explicit text sizes and concise labels. Preserve query expressions, status meanings, incident thresholds and datasource UIDs. Prefer this over splitting the merged summary or adding a custom plugin.

**Tech Stack:** Provisioned Grafana JSON, native Stat panel, existing shell contracts, isolated Grafana 11.2 preview and installed Playwright/Chromium.

## Constraints

- All ten status values and their risk semantics remain visible in the same summary.
- Preserve the recently deployed latest-logs-before-critical-events order.
- The user reports refresh has recovered and asked to focus on mobile; no latency/runtime changes are part of this implementation.
- Preview uses synthetic datasource responses in an isolated loopback-only Grafana instance, never real trading actions or production auth changes.

## Phase 1: Reproduce and choose dimensions

- [x] Render baseline at 390 px and candidate at 320, 360, 390, 430 and 1280 px using the same Grafana 11.2 image as production. Baseline label/value fonts shrink to 4.3125/10.2667 px.
- [x] Start candidate with height 8: 320 px preview exposes overflowing risk text. Increase to 10 grid units with automatic grid, 14 px labels, 20 px values and wide layout disabled. All existing labels fit without changing wording.
- [x] Check bounding boxes and screenshots for normal status and risk/duplicate-process states with four-digit incident counts: all ten cards at all five widths have no text overflow and no browser errors. Native compact-number suffix remains 16 px.

## Phase 2: Apply and verify

- [x] Update `grafana/dashboards/Trading/trading-strategy-detail.json`: accepted summary layout, version 7, shift following panels down by seven grid units.
- [x] Update only affected existing assertions in `tests/trading/test-central-config.sh`; compare queries/mappings/thresholds against baseline to protect status meaning.
- [x] Run central Trading contracts, all dashboard JSON parsing and `git diff --check`; document fresh preview evidence in `docs/work-log.md`.

## Phase 3: Publish and deploy

- [ ] Commit, fetch/rebase, push and open a PR against master; merge under the session's existing deployment authorization.
- [ ] Fast-forward the clean central checkout to the verified merge commit and confirm Grafana provisioning matches the Git source.
- [ ] Verify all three production strategies still return the ten status results; remove isolated preview resources and the clean merged task worktree.
