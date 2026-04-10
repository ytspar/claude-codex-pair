import Foundation

// MARK: - Feedback handling (extracted from ClaudeMonitor.swift)
// Dispatches Codex responses: skip, accept-edits, selection, unmatched, queued, or inject.

extension ClaudeMonitor {

    func handleFeedback(response: String, screenText: String, session: PairSession, st: SessionMonitorState, isSelection: Bool, durationMs: Int?, screenSnippet: String, prompt: String, diffSummary: String?) {
        // Phase is already .feedback from caller's transition

        // If monitor is paused (test harness), discard feedback silently
        if st.paused {
            PairLog.info("[\(session.id)] Monitor paused — discarding Codex feedback")
            return
        }

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
            // Re-verify the screen is STILL a selection prompt right now.
            // The screen may have changed since the review was triggered.
            let freshScreen = session.readScreen()
            let stillSelection = Self.isSelectionPrompt(freshScreen)
            if !stillSelection {
                PairLog.info("[\(session.id)] Selection prompt gone on re-check — discarding option \(option)")
                addTimeline(st, "SKIPPED", "Selection vanished on re-read, option \(option) discarded", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet)
            } else if st.consecutiveSelects > 5 {
                PairLog.error("[\(session.id)] Selection prompt stuck, sending Escape")
                addTimeline(st, "SELECT", "Escape (selection stuck after \(st.consecutiveSelects) tries)")
                st.consecutiveSelects = 0; session.sendEscape()
            } else {
                st.consecutiveSelects += 1
                PairLog.info("[\(session.id)] Selection prompt, typing \(option) + Enter")
                addTimeline(st, "SELECT", "Selecting option \(option)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
                session.injectInput("\(option)\r")
            }
        } else if isSelection && !isNumericResponse {
            // Re-verify selection is still on screen
            let freshScreen = session.readScreen()
            if !Self.isSelectionPrompt(freshScreen) {
                PairLog.info("[\(session.id)] Selection prompt gone on re-check — treating as normal feedback")
                let cleaned = Self.stripLearnings(response)
                if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
                addTimeline(st, "FEEDBACK", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
            } else {
                let ledger = CodexLedger(projectDir: session.cwd)
                ledger.recordUnmatchedPrompt(screenTail: screenSnippet, expectedCategory: "selection", codexResponse: trimmed)
                PairLog.info("[\(session.id)] Selection prompt got non-numeric response '\(trimmed.prefix(50))' — recorded for pattern improvement")
                addTimeline(st, "UNMATCHED", "Selection expected number, got: \(trimmed.prefix(80))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true; session.sendEnter()
            }
        } else if userTypedDuringReview {
            st.consecutiveSelects = 0
            PairLog.info("[\(session.id)] User typed during review — queueing Codex feedback")
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            addTimeline(st, "FEEDBACK", "Queued (user also responded): \(response)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
        } else {
            st.consecutiveSelects = 0
            // Guard against bare numeric responses being injected as text when there's no
            // selection prompt — Codex sometimes responds with just a number to conversational
            // questions, which confuses Claude ("Not sure what '2' refers to").
            if isNumericResponse && !isSelection {
                PairLog.info("[\(session.id)] Bare numeric response '\(trimmed)' without selection prompt — discarding")
                addTimeline(st, "SKIPPED", "Bare number '\(trimmed)' discarded (no selection prompt)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else {
                // Sanity check: validate response before injecting
                if let reason = validateResponse(trimmed, screenText: screenText, session: session) {
                    PairLog.info("[\(session.id)] Response failed sanity check: \(reason)")
                    addTimeline(st, "SKIPPED", "Sanity check: \(reason)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
                } else {
                    // Skip duplicate responses — prevents "commit your changes" loops
                    let cleaned = Self.stripLearnings(response)
                    let lastResponse = st.lastCodexResponse
                    let isDuplicate = !cleaned.isEmpty && cleaned.prefix(60) == lastResponse.prefix(60)
                    if isDuplicate {
                        PairLog.info("[\(session.id)] Duplicate Codex response — skipping: '\(cleaned.prefix(50))'")
                        addTimeline(st, "SKIPPED", "Duplicate response: \(cleaned.prefix(60))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
                    } else {
                        addTimeline(st, "FEEDBACK", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                        st.hadInteraction = true
                        if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
                    }
                }
            }
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

    // MARK: - Response sanity checks

    /// Validate a Codex response before injecting. Returns nil if valid,
    /// or a reason string if the response should be discarded.
    private func validateResponse(_ response: String, screenText: String, session: PairSession) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Too short to be useful (single word/char that isn't APPROVE)
        if trimmed.count < 3 && !trimmed.uppercased().contains("APPROVE") {
            return "Response too short (\(trimmed.count) chars): '\(trimmed)'"
        }

        // 2. Too long — will flood Claude's prompt and waste context
        if trimmed.count > 1000 {
            return "Response too long (\(trimmed.count) chars) — truncating would lose meaning"
        }

        // 3. Dangerous commands that could cause data loss
        let dangerous = ["rm -rf /", "git push --force", "git reset --hard", "drop table", "format c:", "sudo rm"]
        for cmd in dangerous where lower.contains(cmd) {
            return "Dangerous command detected: '\(cmd)'"
        }

        // 4. Self-referential nonsense — Codex talking about itself or the monitor
        if lower.contains("as codex") || lower.contains("as the codex") || lower.contains("i am codex") {
            return "Self-referential response (Codex talking about itself)"
        }

        // 5. Commit loop detection — "commit" when git shows nothing to commit
        if lower.contains("commit") && (lower.contains("your changes") || lower.contains("what you have")) {
            // Check if there are actually uncommitted changes
            let uncommitted = CodexLedger(projectDir: session.cwd).hasUncommittedWork()
            if uncommitted == nil || uncommitted?.files == 0 {
                return "Commit nudge but no uncommitted changes — nothing to commit"
            }
        }

        // 6. Response looks like a system/error message, not actionable feedback
        if lower.hasPrefix("error:") || lower.hasPrefix("warning:") || lower.hasPrefix("fatal:") {
            return "Response looks like an error message, not feedback"
        }

        // 7. Response is just repeating the screen content back
        let screenLower = screenText.lowercased()
        if trimmed.count > 20, screenLower.contains(lower.prefix(60)) {
            return "Response appears to echo screen content"
        }

        return nil // Valid
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
        // Gentle backoff: first 5 unhelpful reviews are free (conversations, planning).
        // After that, gradually slow down to avoid loops like repeated "commit" nudges.
        // Caps at 4x (review every ~12s instead of ~3s). Resets on any "improved" outcome.
        let streak = st.consecutiveUnhelpful
        if streak <= 5 {
            st.backoffMultiplier = 1.0
        } else {
            let exponent = min(Double(streak - 5), 4.0) // 0..4
            st.backoffMultiplier = min(pow(1.5, exponent), 4.0) // 1.0, 1.5, 2.25, 3.375, 4.0
        }
    }
}
