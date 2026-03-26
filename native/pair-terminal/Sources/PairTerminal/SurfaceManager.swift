import Foundation
import Bridge

/// Manages all terminal surfaces and implements the IPC delegate.
class SurfaceManager: IPCServerDelegate {
    private var surfaces: [String: TerminalSurface] = [:]
    private let lock = NSLock()

    /// Create and start a new surface for a Claude session.
    @discardableResult
    func createSurface(id: String, cwd: String, command: [String]? = nil) throws -> TerminalSurface {
        let surface = TerminalSurface(
            id: id,
            cwd: cwd,
            command: command ?? ["/usr/bin/env", "claude"]
        )
        try surface.start()

        lock.lock()
        surfaces[id] = surface
        lock.unlock()

        return surface
    }

    /// Get a surface by ID, or by partial match (prefix, project name).
    func findSurface(_ query: String) -> TerminalSurface? {
        lock.lock()
        defer { lock.unlock() }

        // Exact match
        if let surface = surfaces[query] { return surface }

        // Prefix match
        if let match = surfaces.first(where: { $0.key.hasPrefix(query) }) {
            return match.value
        }

        // Project name match (last path component of CWD)
        let lower = query.lowercased()
        if let match = surfaces.first(where: {
            let project = $0.value.cwd.split(separator: "/").last?.lowercased() ?? ""
            return project.contains(lower)
        }) {
            return match.value
        }

        return nil
    }

    /// Remove a surface.
    func removeSurface(_ id: String) {
        lock.lock()
        let surface = surfaces.removeValue(forKey: id)
        lock.unlock()
        surface?.stop()
    }

    /// List all surfaces.
    func allSurfaces() -> [TerminalSurface] {
        lock.lock()
        defer { lock.unlock() }
        return Array(surfaces.values)
    }

    /// Clean up dead surfaces.
    func pruneDeadSurfaces() {
        lock.lock()
        let dead = surfaces.filter { !$0.value.isAlive }
        for (id, _) in dead {
            surfaces.removeValue(forKey: id)
        }
        lock.unlock()
        for (id, surface) in dead {
            surface.stop()
            NSLog("[SurfaceManager] Pruned dead surface: \(id)")
        }
    }

    // MARK: - IPCServerDelegate

    func handleSendInput(surfaceId: String, text: String) -> IPCResponse {
        guard let surface = findSurface(surfaceId) else {
            return .failure("Surface not found: \(surfaceId)")
        }

        // Send text + newline as user input
        let success = surface.sendLine(text)
        if success {
            return .success("Sent \(text.count) chars to surface \(surface.id)")
        } else {
            return .failure("Failed to write to surface \(surface.id)")
        }
    }

    func handleListSurfaces() -> [SurfaceInfo] {
        return allSurfaces().map { surface in
            SurfaceInfo(
                id: surface.id,
                title: surface.title,
                pid: surface.pid,
                cwd: surface.cwd,
                cols: 120,
                rows: 50
            )
        }
    }

    func handleFocusSurface(surfaceId: String) -> IPCResponse {
        guard findSurface(surfaceId) != nil else {
            return .failure("Surface not found: \(surfaceId)")
        }
        // TODO: When we have a GUI, bring the surface's window to front
        return .success("Focus not yet implemented (headless mode)")
    }

    func handleGetSurface(surfaceId: String) -> IPCResponse {
        guard let surface = findSurface(surfaceId) else {
            return .failure("Surface not found: \(surfaceId)")
        }
        let info = SurfaceInfo(
            id: surface.id,
            title: surface.title,
            pid: surface.pid,
            cwd: surface.cwd,
            cols: 120,
            rows: 50
        )
        if let json = try? JSONEncoder().encode(info),
           let str = String(data: json, encoding: .utf8) {
            return .success(str)
        }
        return .failure("Serialization error")
    }
}
