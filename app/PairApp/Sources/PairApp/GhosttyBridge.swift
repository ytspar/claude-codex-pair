// GhosttyBridge.swift
// Helpers that bridge Swift closures / objects to C function pointers
// required by the ghostty_runtime_config_s callbacks.
//
// Only compiled when USE_GHOSTTY is defined (see Package.swift).

import AppKit
import GhosttyKit

// ---------------------------------------------------------------------------
// MARK: - Callback context
// ---------------------------------------------------------------------------

/// Opaque context passed through `ghostty_runtime_config_s.userdata` and
/// `ghostty_surface_config_s.userdata`.  Prevents the need for global mutable
/// state by carrying references to the owning objects.
final class GhosttyCallbackContext {
    weak var appController: GhosttyAppController?

    init(appController: GhosttyAppController) {
        self.appController = appController
    }
}

/// Per-surface context attached via `ghostty_surface_config_s.userdata`.
final class GhosttySurfaceCallbackContext {
    weak var surfaceView: GhosttyTerminalView?
    let surfaceId: String

    init(surfaceView: GhosttyTerminalView, surfaceId: String) {
        self.surfaceView = surfaceView
        self.surfaceId = surfaceId
    }
}

// ---------------------------------------------------------------------------
// MARK: - App-level singleton that owns the ghostty_app_t
// ---------------------------------------------------------------------------

/// Manages the lifecycle of a single `ghostty_app_t` instance.
/// Created once at app startup; surfaces are created from it.
final class GhosttyAppController {
    static let shared = GhosttyAppController()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var callbackContext: GhosttyCallbackContext?

    /// Whether initialization succeeded.
    var isReady: Bool { app != nil }

    private init() {}

    /// Initialize the Ghostty runtime.  Call once from the main thread.
    func initialize() {
        guard app == nil else { return }

        // ghostty_init
        let result = ghostty_init(0, nil)
        guard result == GHOSTTY_SUCCESS else {
            print("[GhosttyBridge] ghostty_init failed: \(result)")
            return
        }

        // Config
        guard let cfg = ghostty_config_new() else {
            print("[GhosttyBridge] ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        // Runtime callbacks
        let ctx = GhosttyCallbackContext(appController: self)
        self.callbackContext = ctx
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = ctxPtr
        runtime.supports_selection_clipboard = false

        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                GhosttyAppController.shared.tick()
                ClaudeMonitor.shared.recordActivity()
            }
        }

        runtime.action_cb = { _, target, action in
            return GhosttyAppController.shared.handleAction(target: target, action: action)
        }

        runtime.read_clipboard_cb = { userdata, location, state in
            // The read callback must return synchronously whether a clipboard
            // value is available.  We schedule the actual delivery on the main
            // queue and return `true` to signal "will provide later".
            DispatchQueue.main.async {
                guard let surfaceCtx = GhosttyBridgeHelpers.surfaceContext(from: userdata),
                      let view = surfaceCtx.surfaceView,
                      let surface = view.surface else { return }
                let pasteboard = (location == GHOSTTY_CLIPBOARD_STANDARD) ? NSPasteboard.general : NSPasteboard.general
                let text = pasteboard.string(forType: .string) ?? ""
                text.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
            }
            return true
        }

        runtime.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let surfaceCtx = GhosttyBridgeHelpers.surfaceContext(from: userdata),
                  let view = surfaceCtx.surfaceView,
                  let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtime.write_clipboard_cb = { _, location, contentPtr, len, _ in
            guard let contentPtr, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: contentPtr, count: Int(len))
            var text: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                text = String(cString: dataPtr)
                break
            }
            if let text {
                let pasteboard = (location == GHOSTTY_CLIPBOARD_STANDARD) ? NSPasteboard.general : NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        runtime.close_surface_cb = { userdata, _ in
            guard let surfaceCtx = GhosttyBridgeHelpers.surfaceContext(from: userdata) else { return }
            DispatchQueue.main.async {
                surfaceCtx.surfaceView?.handleSurfaceClosed()
            }
        }

        // Create app
        guard let ghosttyApp = ghostty_app_new(&runtime, cfg) else {
            print("[GhosttyBridge] ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }

        self.app = ghosttyApp
        self.config = cfg
    }

    /// Drive the event loop; called from wakeup callback.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Handle action callbacks from Ghostty.
    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_RENDER_INSPECTOR:
            // Rendering is handled by Metal/CAMetalLayer automatically
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            // Could forward to the tab title
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return true
        default:
            return false
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

enum GhosttyBridgeHelpers {
    /// Extract a `GhosttySurfaceCallbackContext` from the raw userdata pointer
    /// stored on a surface config.
    static func surfaceContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }
}

