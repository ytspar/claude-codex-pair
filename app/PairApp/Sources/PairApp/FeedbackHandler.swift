import Foundation

// MARK: - Feedback handling (extracted from ClaudeMonitor.swift)
// Dispatches Codex responses: skip, accept-edits, selection, unmatched, queued, or inject.

extension ClaudeMonitor {

    func handleFeedback(response: String, screenText: String, session: PairSession, st: SessionMonitorState, isSelection: Bool, durationMs: Int?, screenSnippet: String, prompt: String, diffSummary: String?) {
        // Phase is already .feedback from caller's transition

        // CARDINAL RULE: Re-read the screen RIGHT NOW. If the prompt is not empty,
        // someone (user or prior injection) has text there. Do not touch it.
        let currentScreen = session.readScreen()
        if !isPromptEmpty(currentScreen) && !isSelection {
            PairLog.info("[\(session.id)] Prompt not empty — discarding Codex feedback to protect user input")
            addTimeline(st, "SKIPPED", "Prompt not empty — protected user input", source: .monitor, durationMs: durationMs, codexPrompt: prompt, codexResponse: response)
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNumericResponse = Int(trimmed) != nil
        let userTypedDuringReview: Bool = {
            guard let start = st.reviewStartTime else { return false }
            return session.lastInputSource == .user && session.lastMachineInputTime < start
        }()
        let userOwnsInput = session.lastInputSource == .user
        let isAcceptEdits = Self.isAcceptEditsPrompt(screenText)
        let codexWantsApprove = response.uppercased().contains("APPROVE") || isNumericResponse

        if userOwnsInput {
            st.consecutiveSelects = 0
            PairLog.info("[\(session.id)] User is typing — discarding Codex response, user owns this input")
            addTimeline(st, "SKIPPED", "User is typing — Codex deferred: \(response)", source: .user, durationMs: durationMs, codexPrompt: prompt, codexResponse: response)
        } else if isAcceptEdits && codexWantsApprove {
            st.consecutiveSelects += 1
            if st.consecutiveSelects > 3 {
                PairLog.error("[\(session.id)] Accept-edits prompt stuck, sending Escape")
                addTimeline(st, "SELECT", "Escape (accept-edits stuck after \(st.consecutiveSelects) tries)")
                st.consecutiveSelects = 0; session.sendEscape()
            } else {
                PairLog.info("[\(session.id)] Accept-edits prompt detected, pressing Enter (\(st.consecutiveSelects))")
                addTimeline(st, "SELECT", "Accepting edits (Enter)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet)
                st.hadInteraction = true; session.sendEnter()
            }
        } else if isSelection && isNumericResponse, let option = Int(trimmed) {
            st.consecutiveSelects += 1
            if st.consecutiveSelects > 5 {
                PairLog.error("[\(session.id)] Selection prompt stuck, sending Escape")
                addTimeline(st, "SELECT", "Escape (selection stuck after \(st.consecutiveSelects) tries)")
                st.consecutiveSelects = 0; session.sendEscape()
            } else {
                PairLog.info("[\(session.id)] Selection prompt, typing \(option) + Enter")
                addTimeline(st, "SELECT", "Selecting option \(option)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
                // Type the number directly — arrow keys don't work reliably with Claude Code's TUI
                session.injectInput("\(option)\r")
            }
        } else if isSelection && !isNumericResponse {
            // Category mismatch: detected as selection prompt but Codex didn't return a number.
            // Record for self-improvement, then try to handle gracefully.
            let ledger = CodexLedger(projectDir: session.cwd)
            ledger.recordUnmatchedPrompt(screenTail: screenSnippet, expectedCategory: "selection", codexResponse: trimmed)
            PairLog.info("[\(session.id)] Selection prompt got non-numeric response '\(trimmed.prefix(50))' — recorded for pattern improvement")
            addTimeline(st, "UNMATCHED", "Selection expected number, got: \(trimmed.prefix(80))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            // Try pressing Enter as fallback (selects default/first option)
            st.hadInteraction = true; session.sendEnter()
        } else if userTypedDuringReview {
            st.consecutiveSelects = 0
            PairLog.info("[\(session.id)] User typed during review — queueing Codex feedback")
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            addTimeline(st, "FEEDBACK", "Queued (user also responded): \(response)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
        } else {
            st.consecutiveSelects = 0
            addTimeline(st, "FEEDBACK", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
        }
        // After feedback, wait for the screen to actually change before reviewing again.
        // The 1s cooldown was too aggressive — Codex would re-trigger on the same prompt.
        // Require at least 5s AND a screen change before the next review.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.transitionAndSync(st, to: .watching, reason: "post-feedback cooldown")
            st.stableCount = 0
            st.changeCount = 0  // Force waiting for new screen changes
        }
    }

    // MARK: - User feedback (thumbs up/down)

    /// Rate an intervention as helpful or unhelpful. Overrides the git-based outcome.
    func rateIntervention(entryId: UUID, rating: String) {
        // Update session counters based on user rating
        if rating == "improved" {
            sessionImproved += 1
            // User says it helped — reduce backoff
            if let activeId = SessionManager.shared.activeSessionId,
               let st = sessionStatesLock.withLock({ sessionStates[activeId] }) {
                st.consecutiveUnhelpful = max(0, st.consecutiveUnhelpful - 1)
                if st.consecutiveUnhelpful < 3 { st.backoffMultiplier = 1.0 }
                syncPublished()
            }
        } else if rating == "regressed" {
            sessionRegressed += 1
            // User says it hurt — increase backoff
            if let activeId = SessionManager.shared.activeSessionId,
               let st = sessionStatesLock.withLock({ sessionStates[activeId] }) {
                st.consecutiveUnhelpful += 1
                updateBackoff(st)
                syncPublished()
            }
        }
        // Find the timeline entry and log the rating
        if let activeId = SessionManager.shared.activeSessionId,
           let st = sessionStatesLock.withLock({ sessionStates[activeId] }),
           let entry = st.timeline.first(where: { $0.id == entryId }) {
            PairLog.info("[\(activeId)] User rated intervention '\(entry.event)' as \(rating)")
            // Record to ledger for strategy learning
            if let cwd = SessionManager.shared.sessions.first(where: { $0.id == activeId })?.cwd {
                let ledger = CodexLedger(projectDir: cwd)
                ledger.appendLearning("User rated '\(entry.detail.prefix(60))' as \(rating)")
            }
        }
    }

    // MARK: - Backoff management

    func updateBackoff(_ st: SessionMonitorState) {
        // Backoff disabled: the system should always keep moving forward.
        // Claude conversations often don't produce git commits (questions,
        // discussions, planning) — that's normal, not a reason to slow down.
        // The backoff counter is still tracked for UI/logging but multiplier stays at 1.
        st.backoffMultiplier = 1.0
    }
}
