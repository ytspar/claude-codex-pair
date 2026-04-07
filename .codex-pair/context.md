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

## 2026-04-03 18:52
After a logical checkpoint commit, the next step should be runtime verification or repro-based testing, not more repository inspection.

## 2026-04-03 18:52
After a logical checkpoint, prefer execution/repro verification over more inspection; repeated “commit now” nudges without verification are looping.

## 2026-04-03 18:52
After a logical checkpoint, commit nudges without execution are looping; prefer runtime verification/repro first.

## 2026-04-03 18:52
After a logical checkpoint, repeated repo inspection or commit nudges without execution are looping; prefer runtime or repro-based verification first.

## 2026-04-03 18:53
After a logical checkpoint with builds/tests passing, prefer repo-provided UI/runtime verification or direct repro over more inspection or commit nudges.

## 2026-04-03 18:54
After builds/tests pass at a logical checkpoint, the next step is repo-provided runtime or repro verification, not more inspection and not another commit nudge.

## 2026-04-03 18:54
After builds/tests pass at a logical checkpoint, the next intervention should be repo-provided runtime/repro verification first; commit nudges come after verification, not before.

## 2026-04-03 18:54
After builds/tests pass at a logical checkpoint, the next step is runtime/repro verification first; repeated inspection or commit nudges before verification are looping.

## 2026-04-03 18:54
After builds/tests pass at a logical checkpoint, the next intervention should be runtime/repro verification first; commit nudges before verification are looping.

## 2026-04-03 18:55
After builds/tests pass at a logical checkpoint, the next intervention should be repo-provided runtime/repro verification first; repeated inspection or commit nudges before verification are looping.

## 2026-04-03 18:55
After a logical checkpoint with builds/tests passing, prefer repo-provided runtime or repro verification before any further inspection or commit nudge.

## 2026-04-03 18:55
After builds/tests pass at a logical checkpoint, prefer repo-provided runtime or repro verification before any further inspection or commit nudge.

## 2026-04-03 18:55
After builds/tests pass at a logical checkpoint, the next intervention should be repo-provided runtime or repro verification first; commit nudges come after verification, not before.

## 2026-04-03 18:55
After builds/tests pass at a logical checkpoint, the next intervention should be runtime or repro verification first; repeated inspection, context-note edits, or commit nudges before verification are looping.

## 2026-04-03 18:56
After a logical checkpoint with builds/tests passing, the next intervention must be runtime/repro verification first; repeated repo inspection, context-note edits, or pre-verification commit nudges are looping.

## 2026-04-03 18:56
After a logical checkpoint with passing builds/tests, runtime/repro verification comes before more inspection or context-note edits; commit right after verification.

## 2026-04-03 18:57
After builds/tests pass at a logical checkpoint, the next intervention is runtime or repro verification first; pre-verification commit nudges and repeated context-note edits are looping.

## 2026-04-03 18:57
After builds/tests pass at a logical checkpoint, runtime/repro verification must happen before more inspection, context-note edits, or commit nudges.

## 2026-04-03 18:57
After builds/tests pass at a logical checkpoint, the next useful intervention is runtime/repro verification first; commit immediately after successful verification.

## 2026-04-03 18:57
After builds/tests pass at a logical checkpoint, the next useful step is runtime/repro verification first; commit immediately after successful verification.

## 2026-04-03 18:59
After builds/tests pass at a logical checkpoint, the next useful intervention is runtime/repro verification first; repeated inspection, context-note edits, or pre-verification commit nudges are looping.

## 2026-04-03 18:59
After builds/tests pass at a logical checkpoint, the next useful step is runtime/repro verification; repeated inspection or context-note edits are looping, and the commit should happen right after successful verification.

## 2026-04-03 19:00
After builds/tests pass at a logical checkpoint, switch to runtime/repro verification; repeated repo inspection, context-note edits, or pre-verification commit nudges are looping.

## 2026-04-03 19:00
After builds/tests pass at a logical checkpoint, the next useful step is runtime/repro verification; repeated repo inspection, context-note edits, or pre-verification commit nudges are looping.

## 2026-04-03 19:00
After builds/tests pass at a logical checkpoint, the next useful intervention is runtime/repro verification; repeated inspection or context-note edits are looping.

## 2026-04-03 19:00
After builds/tests pass at a logical checkpoint, the next useful step is runtime/repro verification; repeated inspection or context-note churn is looping.

## 2026-04-03 19:01
After builds/tests pass at a logical checkpoint, the next useful step is commit + runtime/repro verification; repeated repo inspection, context-note edits, or pre-verification nudges are looping.

## 2026-04-03 19:01
After builds/tests pass at a logical checkpoint, prefer commit + runtime/repro verification; repeated repo inspection and context-note edits are looping.

## 2026-04-03 19:01
After builds/tests pass at a logical checkpoint, prefer commit + runtime/repro verification; repeated repo inspection and context-note edits are looping.

## 2026-04-03 19:12
After builds/tests pass at a logical checkpoint, prefer commit + runtime/repro verification; repeated repo inspection or context-note edits are looping.

## 2026-04-03 19:12
After builds/tests pass at a logical checkpoint, the next useful step is commit followed by runtime/repro verification; repeated repo inspection or context-note edits are looping.

## 2026-04-03 19:12
After builds/tests pass at a logical checkpoint, commit once, then switch to runtime/repro verification; repeated context-note edits or repeated commit nudges are a loop.

## 2026-04-03 19:12
After builds/tests pass and there are meaningful uncommitted changes, commit once and switch to runtime/repro verification; repeated context-note edits, repo inspection, or repeated commit nudges are loops.

## 2026-04-03 19:12
After builds/tests pass at a logical checkpoint and there are meaningful uncommitted changes, commit once, then move to runtime/repro verification; repeated repo inspection or context-note edits are looping.

## 2026-04-03 19:12
After builds/tests pass at a logical checkpoint with meaningful uncommitted changes, commit once, then move to runtime/repro verification; repeated `.codex-pair/context.md` edits, repo inspection, or repeated commit nudges are loops.

## 2026-04-03 19:13
After a logical checkpoint with passing builds/tests and meaningful uncommitted work, commit once, then move to runtime/repro verification; repeated context-note edits or repo inspection are loops.

## 2026-04-03 19:13
After passing builds/tests with meaningful uncommitted work, commit once, then do runtime/repro verification; repeated `.codex-pair/context.md` edits or repo inspection are loops.

## 2026-04-03 19:13
After passing builds/tests with meaningful uncommitted work, commit once, then move immediately to runtime or repro verification; repeated context-note edits, repo inspection, or repeated commit nudges are loops.

## 2026-04-03 19:13
after a green checkpoint, one commit plus runtime/repro verification is the correct next step; repeated commit nudges or context-note edits are loops.

## 2026-04-03 19:13
After a green checkpoint with meaningful uncommitted work, the effective next sequence is one commit followed immediately by runtime/repro verification; repeated context-note edits, repo inspection, or repeated commit reminders are loops.

## 2026-04-07 11:50
After a green checkpoint with meaningful uncommitted work, the next step is one commit followed immediately by runtime/repro verification; repeated context-note edits, repo inspection, or repeated commit nudges are loops.

## 2026-04-07 12:19
After a green checkpoint with meaningful uncommitted work, the next step is one commit followed immediately by runtime/repro verification; repeated context-note edits, repo inspection, or repeated commit nudges are loops.
