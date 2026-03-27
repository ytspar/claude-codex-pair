import SwiftUI

/// Shows auth status for Claude and Codex on launch.
/// If both are ready, auto-proceeds to directory picker.
struct AuthStatusView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var status: AuthChecker.AuthStatus?
    @State private var isChecking = true
    let onReady: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 48))
                .foregroundColor(themeManager.accent)

            Text("Checking Authentication")
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundColor(themeManager.text)

            if isChecking {
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(.circular)
            } else if let status = status {
                VStack(alignment: .leading, spacing: 12) {
                    // Claude status
                    AuthRow(
                        name: "Claude Code",
                        installed: status.claudeInstalled,
                        authenticated: status.claudeAuthenticated,
                        detail: status.claudeInstalled ? status.claudeVersion : "not found",
                        authMethod: status.claudeInstalled && status.claudeAuthenticated ? "session" : nil
                    )

                    // Codex status
                    AuthRow(
                        name: "Codex CLI",
                        installed: status.codexInstalled,
                        authenticated: status.codexAuthenticated,
                        detail: status.codexInstalled ? status.codexVersion : "not found",
                        authMethod: status.codexAuthenticated ? status.codexAuthMethod : nil
                    )
                }
                .padding(.horizontal, 40)

                if !status.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(status.issues, id: \.self) { issue in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                    .foregroundColor(themeManager.warning)
                                Text(issue)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(themeManager.warning)
                            }
                        }
                    }
                    .padding(.horizontal, 40)

                    Button("Retry") {
                        checkAuth()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(themeManager.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(themeManager.accent, lineWidth: 1.5)
                    )

                    Button("Continue Anyway") {
                        onReady()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
                }
            }
        }
        .onAppear { checkAuth() }
    }

    private func checkAuth() {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AuthChecker.check()
            DispatchQueue.main.async {
                status = result
                isChecking = false
                if result.allReady {
                    // Auto-proceed after brief delay to show green checkmarks
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        onReady()
                    }
                }
            }
        }
    }
}

struct AuthRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let name: String
    let installed: Bool
    let authenticated: Bool
    let detail: String
    let authMethod: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: installed && authenticated ? "checkmark.circle.fill" : installed ? "exclamationmark.circle" : "xmark.circle")
                .font(.system(size: 16))
                .foregroundColor(installed && authenticated ? themeManager.accent : installed ? themeManager.warning : themeManager.error)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(themeManager.text)
                HStack(spacing: 6) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(themeManager.textMuted)
                    if let method = authMethod {
                        Text("(\(method))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(themeManager.textSecondary)
                    }
                }
            }

            Spacer()
        }
    }
}
