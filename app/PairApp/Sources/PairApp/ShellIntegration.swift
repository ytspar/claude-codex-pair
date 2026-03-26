import Foundation

/// Shell integration — injects environment variables and hooks into zsh/bash
/// using the ZDOTDIR trick (same pattern as cmux).
class ShellIntegration {
    static let shared = ShellIntegration()

    let integrationDir: String

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        integrationDir = "\(home)/.claude-codex-pair/shell-integration"
        ensureIntegrationScripts()
    }

    /// Build environment for a new terminal session.
    func environment(sessionId: String, cwd: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["PAIR_SESSION_ID"] = sessionId
        env["PAIR_SOCKET_PATH"] = IPCServer.socketPath
        env["PAIR_SHELL_INTEGRATION"] = "1"
        env["PAIR_SHELL_INTEGRATION_DIR"] = integrationDir
        env["TERM"] = "xterm-256color"

        // ZDOTDIR trick for zsh
        if let shell = env["SHELL"], shell.hasSuffix("zsh") {
            let realZdotdir = env["ZDOTDIR"] ?? env["HOME"] ?? ""
            env["PAIR_REAL_ZDOTDIR"] = realZdotdir
            env["ZDOTDIR"] = integrationDir
        }

        return env
    }

    private func ensureIntegrationScripts() {
        let dir = integrationDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let zshrc = """
        # PairApp shell integration — injected via ZDOTDIR
        if [[ -n "$PAIR_REAL_ZDOTDIR" ]] && [[ -f "$PAIR_REAL_ZDOTDIR/.zshrc" ]]; then
            ZDOTDIR="$PAIR_REAL_ZDOTDIR"
            source "$PAIR_REAL_ZDOTDIR/.zshrc"
        elif [[ -f "$HOME/.zshrc" ]]; then
            ZDOTDIR="$HOME"
            source "$HOME/.zshrc"
        fi
        export ZDOTDIR="${PAIR_REAL_ZDOTDIR:-$HOME}"

        _pair_precmd() {
            if [[ -n "$PAIR_SOCKET_PATH" ]]; then
                printf 'report_pwd %s' "$PWD" | nc -U "$PAIR_SOCKET_PATH" 2>/dev/null &!
            fi
        }

        _pair_preexec() {
            if [[ -n "$PAIR_SOCKET_PATH" ]]; then
                printf 'report_cmd %s' "$1" | nc -U "$PAIR_SOCKET_PATH" 2>/dev/null &!
            fi
        }

        autoload -Uz add-zsh-hook 2>/dev/null
        if (( $+functions[add-zsh-hook] )); then
            add-zsh-hook precmd _pair_precmd
            add-zsh-hook preexec _pair_preexec
        fi
        """

        let zshenv = """
        if [[ -n "$PAIR_REAL_ZDOTDIR" ]] && [[ -f "$PAIR_REAL_ZDOTDIR/.zshenv" ]]; then
            source "$PAIR_REAL_ZDOTDIR/.zshenv"
        elif [[ -f "$HOME/.zshenv" ]]; then
            source "$HOME/.zshenv"
        fi
        """

        let zprofile = """
        if [[ -n "$PAIR_REAL_ZDOTDIR" ]] && [[ -f "$PAIR_REAL_ZDOTDIR/.zprofile" ]]; then
            source "$PAIR_REAL_ZDOTDIR/.zprofile"
        elif [[ -f "$HOME/.zprofile" ]]; then
            source "$HOME/.zprofile"
        fi
        """

        try? zshrc.write(toFile: "\(dir)/.zshrc", atomically: true, encoding: .utf8)
        try? zshenv.write(toFile: "\(dir)/.zshenv", atomically: true, encoding: .utf8)
        try? zprofile.write(toFile: "\(dir)/.zprofile", atomically: true, encoding: .utf8)
    }
}
