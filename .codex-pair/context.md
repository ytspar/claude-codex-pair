# Codex Project Context

Learnings from reviewing Claude's work in this project.

## 2026-04-02 23:25
This app uses native AppKit menu conventions; prefer standard macOS labels/order like `Open…` / `Open Recent` over custom menu naming.

## 2026-04-02 23:39
This app already provides its own session tabs via `SessionToolbar`, so native macOS window tabbing should stay disabled to avoid duplicate chrome and theme mismatches.

## 2026-04-02 23:46
This app already provides its own session tabs via `SessionToolbar`, so native macOS window tabbing should stay disabled even when adjusting titlebar appearance.

## 2026-04-02 23:59
This app prefers standard macOS/AppKit File menu naming and ordering, including `Open…` and `Open Recent`, instead of custom labels like `Browse…`.

## 2026-04-03 00:12
This app’s automation logic is priority-sensitive; when Claude is at a prompt, queued task dequeue must win over stuck detection, and stuck detection should only run as a fallback when no queued work is available.

## 2026-04-03 17:57
This app already has its own session tabs and prefers standard AppKit File menu conventions, so titlebar/menu work should not re-enable native tabbing or rename File menu items.

## 2026-04-03 18:00
When there are already substantial uncommitted changes, save progress with a commit before pushing further; this has been improving outcomes.

## 2026-04-03 18:07
When there are already substantial uncommitted changes, commit at a logical checkpoint before further iteration; this has been improving outcomes and helps break loop patterns.

## 2026-04-03 18:08
After a logical checkpoint commit, the next intervention should usually be execution/verification, not more git inspection or another commit-oriented loop.

## 2026-04-03 18:09
After a logical checkpoint commit, switch immediately to runtime verification or repro-based testing instead of more git inspection.

## 2026-04-03 18:09
After a logical checkpoint commit, switch immediately to runtime verification or repro testing instead of more git inspection.

## 2026-04-03 18:09
After a logical checkpoint commit, switch immediately to execution/verification rather than more repository inspection.

## 2026-04-03 18:09
After a logical checkpoint commit, immediately switch to runtime verification or repro-based testing instead of more repository inspection.

## 2026-04-03 18:09
After a logical checkpoint commit, switch immediately to runtime verification or repro-based testing instead of more repository inspection.

## 2026-04-03 18:10
After a logical checkpoint commit, immediately switch to runtime verification or repro-based testing instead of more repository inspection.

## 2026-04-03 18:10
After a logical checkpoint commit, the next step should be execution or repro-based verification, not more repository inspection.

## 2026-04-03 18:47
After a logical checkpoint commit, the next intervention should be runtime verification or repro testing, not more repository inspection.
