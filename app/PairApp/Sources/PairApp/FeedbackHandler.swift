import Foundation

// MARK: - Feedback handling (simplified)
// The reviewer sees the raw terminal and responds with what a human would type.
// No prompt classification, no selection detection, no special dispatch paths.
// Just: validate → type it in (or do nothing if WAIT/APPROVE).

extension ClaudeMonitor {

    func handleFeedback(response: String, screenText: String, session: PairSession, st: SessionMonitorState, isSelection: Bool, durationMs: Int?, screenSnippet: String, prompt: String, diffSummary: String?) {
        // If monitor is paused (test harness), discard silently
        if st.paused {
            PairLog.info("[\(session.id)] Monitor paused — discarding feedback")
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. User is actively typing — never interfere
        let userOwnsInput = session.lastInputSource == .user && -session.lastUserInputTime.timeIntervalSinceNow < 10
        if userOwnsInput {
            PairLog.info("[\(session.id)] User is typing — discarding reviewer response")
            addTimeline(st, "SKIPPED", "User is typing — deferred", source: .user, durationMs: durationMs, codexPrompt: prompt, codexResponse: response)
            return
        }

        let userTypedDuringReview: Bool = {
            guard let start = st.reviewStartTime else { return false }
            return session.lastInputSource == .user && session.lastMachineInputTime < start
        }()
        if userTypedDuringReview {
            PairLog.info("[\(session.id)] User typed during review — queueing feedback")
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            addTimeline(st, "FEEDBACK", "Queued (user responded): \(response)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
            scheduleReturnToWatching(st)
            return
        }

        // 2. Parse structured decision
        let decision = CodexDecision.parse(trimmed)

        switch decision {
        case .approve:
            if isSelection || Self.isAcceptEditsPrompt(screenText) {
                PairLog.info("[\(session.id)] APPROVE on interactive prompt — skipped; reviewer must use SELECT")
                addTimeline(st, "SKIPPED", "APPROVE ignored on interactive prompt; expected SELECT: <number>", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            } else {
                addTimeline(st, "APPROVED", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            }

        case .wait:
            PairLog.info("[\(session.id)] Reviewer says WAIT")
            addTimeline(st, "WAIT", "Reviewer says wait", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)

        case .escalate(let reason):
            PairLog.info("[\(session.id)] ESCALATED: \(reason)")
            addTimeline(st, "ESCALATE", reason, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            NotificationStore.shared.addNotification(sessionId: session.id, title: "Reviewer escalated", body: reason)

        case .answer(let text), .redirect(let text):
            let eventType = decision.isRedirect ? "REDIRECT" : "FEEDBACK"
            let cleaned = Self.stripLearnings(text)

            // Sanity checks
            if let reason = validateResponse(cleaned, screenText: screenText, session: session) {
                PairLog.info("[\(session.id)] Response failed sanity check: \(reason)")
                addTimeline(st, "SKIPPED", "Sanity: \(reason)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else if isDuplicateResponse(cleaned, st: st) {
                PairLog.info("[\(session.id)] Duplicate response — skipping")
                addTimeline(st, "SKIPPED", "Duplicate: \(cleaned.prefix(60))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else {
                addTimeline(st, eventType, response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
                if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            }

        case .select(let option):
            // The reviewer explicitly wants to select a menu option.
            // Use arrow-key navigation since TUI selects don't accept typed numbers.
            PairLog.info("[\(session.id)] SELECT \(option) via arrow keys")
            if session.selectOption(option, screenText: screenText) {
                addTimeline(st, "SELECT", "Selecting option \(option)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
            } else {
                let reason = "Invalid SELECT option \(option) for visible menu"
                addTimeline(st, "ESCALATE", reason, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                NotificationStore.shared.addNotification(sessionId: session.id, title: "Reviewer selection failed", body: reason)
            }

        case .unknown(let text):
            let cleaned = Self.stripLearnings(text)

            // Bare numbers without SELECT: prefix — discard (prevents false injections)
            if Int(trimmed) != nil {
                PairLog.info("[\(session.id)] Bare number '\(trimmed)' — discarding (use SELECT: N)")
                addTimeline(st, "SKIPPED", "Bare number '\(trimmed)' discarded", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else if let reason = validateResponse(cleaned, screenText: screenText, session: session) {
                PairLog.info("[\(session.id)] Sanity check: \(reason)")
                addTimeline(st, "SKIPPED", "Sanity: \(reason)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else if isDuplicateResponse(cleaned, st: st) {
                PairLog.info("[\(session.id)] Duplicate response — skipping")
                addTimeline(st, "SKIPPED", "Duplicate: \(cleaned.prefix(60))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response)
            } else {
                addTimeline(st, "FEEDBACK", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
                if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            }
        }

        scheduleReturnToWatching(st)
    }

    // MARK: - Helpers

    private func isDuplicateResponse(_ cleaned: String, st: SessionMonitorState) -> Bool {
        let last = st.lastCodexResponse
        return !cleaned.isEmpty && cleaned.prefix(60) == last.prefix(60)
    }

    private func scheduleReturnToWatching(_ st: SessionMonitorState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.transitionAndSync(st, to: .watching, reason: "post-feedback cooldown")
            st.stableCount = 0
            st.changeCount = 0
        }
    }

    // MARK: - Response validation

    /// Validate a response before injecting. Returns nil if valid, or a reason to discard.
    func validateResponse(_ response: String, screenText: String, session: PairSession) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if trimmed.count < 3 { return "Too short (\(trimmed.count) chars)" }
        if trimmed.count > 1000 { return "Too long (\(trimmed.count) chars)" }

        let dangerous = ["rm -rf /", "git push --force", "git reset --hard", "drop table", "sudo rm"]
        for cmd in dangerous where lower.contains(cmd) { return "Dangerous: '\(cmd)'" }

        if lower.contains("as codex") || lower.contains("i am codex") || lower.contains("as the reviewer") {
            return "Self-referential"
        }

        if lower.contains("commit") && (lower.contains("your changes") || lower.contains("what you have")) {
            let uncommitted = CodexLedger(projectDir: session.cwd).hasUncommittedWork()
            if uncommitted == nil || uncommitted?.files == 0 { return "Commit nudge but nothing to commit" }
        }

        if lower.hasPrefix("error:") || lower.hasPrefix("warning:") || lower.hasPrefix("fatal:") {
            return "Looks like an error message"
        }

        return nil
    }

    // MARK: - User feedback

    func rateIntervention(entryId: UUID, rating: String) {
        if rating == "improved" { sessionImproved += 1 }
        else if rating == "regressed" { sessionRegressed += 1 }
        else { sessionNeutral += 1 }

        if let activeId = SessionManager.shared.activeSessionId,
           let st = sessionStatesLock.withLock({ sessionStates[activeId] }) {
            if rating == "improved" {
                st.consecutiveUnhelpful = 0; st.backoffMultiplier = 1.0
            } else {
                st.consecutiveUnhelpful += 1
                updateBackoff(st)
            }
            syncPublished()

            if let entry = st.timeline.first(where: { $0.id == entryId }) {
                PairLog.info("[\(activeId)] User rated '\(entry.event)' as \(rating)")
                if let cwd = SessionManager.shared.sessions.first(where: { $0.id == activeId })?.cwd {
                    CodexLedger(projectDir: cwd).appendLearning("User rated '\(entry.detail.prefix(60))' as \(rating)")
                }
            }
        }
    }

    func updateBackoff(_ st: SessionMonitorState) {
        let streak = st.consecutiveUnhelpful
        if streak <= 5 {
            st.backoffMultiplier = 1.0
        } else {
            let exponent = min(Double(streak - 5), 4.0)
            st.backoffMultiplier = min(pow(1.5, exponent), 4.0)
        }
    }
}

// MARK: - CodexDecision helpers

extension CodexDecision {
    var isRedirect: Bool {
        if case .redirect = self { return true }
        return false
    }
}
