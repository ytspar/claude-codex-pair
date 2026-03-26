// GhosttyTerminalView.swift
// NSView subclass that hosts a Ghostty terminal surface rendered via Metal.
//
// Only compiled when USE_GHOSTTY is defined (see Package.swift).

#if USE_GHOSTTY
import AppKit
import Metal
import QuartzCore
import SwiftUI
import GhosttyKit

// ---------------------------------------------------------------------------
// MARK: - GhosttyTerminalView (NSView)
// ---------------------------------------------------------------------------

/// An NSView backed by a CAMetalLayer that drives a single Ghostty terminal
/// surface.  The surface owns its own PTY (via `ghostty_surface_new`) and
/// renders into the Metal layer on each frame.
final class GhosttyTerminalView: NSView {

    // Ghostty handles
    private(set) var surface: ghostty_surface_t?
    private var surfaceCallbackContext: GhosttySurfaceCallbackContext?

    // Configuration
    private let workingDirectory: String
    private let command: String?

    /// Callback invoked when the child process exits.
    var onSurfaceClosed: (() -> Void)?

    // Track whether the view has been attached to a window (and surface created)
    private var surfaceCreated = false

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    init(workingDirectory: String, command: String? = nil) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !surfaceCreated {
            createSurface()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMetalLayerSize()
        updateSurfaceSize()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateMetalLayerSize()
        updateSurfaceSize()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    deinit {
        destroySurface()
    }

    // -----------------------------------------------------------------------
    // Surface creation
    // -----------------------------------------------------------------------

    private func createSurface() {
        guard !surfaceCreated else { return }
        guard let app = GhosttyAppController.shared.app else {
            print("[GhosttyTerminalView] GhosttyAppController not initialized")
            return
        }

        let ctx = GhosttySurfaceCallbackContext(
            surfaceView: self,
            surfaceId: UUID().uuidString
        )
        let retainedCtx = Unmanaged.passRetained(ctx)
        self.surfaceCallbackContext = ctx

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        surfaceConfig.userdata = retainedCtx.toOpaque()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.scale_factor = Double(scale)
        surfaceConfig.font_size = 0 // Use config default

        // Working directory
        workingDirectory.withCString { cwdPtr in
            surfaceConfig.working_directory = cwdPtr

            if let command, !command.isEmpty {
                command.withCString { cmdPtr in
                    surfaceConfig.command = cmdPtr
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        if surface == nil {
            print("[GhosttyTerminalView] ghostty_surface_new returned nil")
            retainedCtx.release()
            surfaceCallbackContext = nil
            return
        }

        surfaceCreated = true
        updateScale()
        updateSurfaceSize()

        // Focus the surface
        if let surface {
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
        }
    }

    private func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let ctx = surfaceCallbackContext {
            // Balance the passRetained in createSurface
            Unmanaged.passUnretained(ctx).release()
            surfaceCallbackContext = nil
        }
        surfaceCreated = false
    }

    // -----------------------------------------------------------------------
    // Size / scale helpers
    // -----------------------------------------------------------------------

    private func updateScale() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
        }
        updateMetalLayerSize()
    }

    private func updateMetalLayerSize() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = bounds.size
        let drawableSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        if metalLayer.drawableSize != drawableSize {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.drawableSize = drawableSize
            metalLayer.contentsScale = scale
            CATransaction.commit()
        }
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        if w > 0 && h > 0 {
            ghostty_surface_set_size(surface, w, h)
        }
    }

    // -----------------------------------------------------------------------
    // Input handling
    // -----------------------------------------------------------------------

    override func keyDown(with event: NSEvent) {
        guard let surface else { super.keyDown(with: event); return }

        let mods = Self.ghosttyMods(from: event.modifierFlags)

        // Send the text if available
        if let chars = event.characters, !chars.isEmpty {
            chars.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
            }
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = mods
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { super.keyUp(with: event); return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.mods = Self.ghosttyMods(from: event.modifierFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        // Forward modifier key changes if needed
        super.flagsChanged(with: event)
    }

    override func insertText(_ insertString: Any) {
        guard let surface else { return }
        let text: String
        if let s = insertString as? String {
            text = s
        } else if let attr = insertString as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        guard !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    // -----------------------------------------------------------------------
    // Mouse handling
    // -----------------------------------------------------------------------

    override func mouseDown(with event: NSEvent) {
        guard let surface else { super.mouseDown(with: event); return }
        let mods = Self.ghosttyMods(from: event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { super.mouseUp(with: event); return }
        let mods = Self.ghosttyMods(from: event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, Double(pt.x), Double(bounds.height - pt.y), mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let mods = Self.ghosttyMods(from: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, Double(pt.x), Double(bounds.height - pt.y), mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { super.scrollWheel(with: event); return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // -----------------------------------------------------------------------
    // Modifier translation
    // -----------------------------------------------------------------------

    private static func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift)   { mods |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option)  { mods |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock){ mods |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // -----------------------------------------------------------------------
    // Surface closed callback
    // -----------------------------------------------------------------------

    func handleSurfaceClosed() {
        onSurfaceClosed?()
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /// Send text input to the terminal (e.g. from paste or IPC).
    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Request the surface to close (will trigger close_surface_cb).
    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }
}

// ---------------------------------------------------------------------------
// MARK: - SwiftUI wrapper
// ---------------------------------------------------------------------------

/// SwiftUI view that wraps the Ghostty terminal.  Drop-in alongside the
/// existing `TerminalContainerView` (SwiftTerm-based).
struct GhosttyTerminalContainerView: NSViewRepresentable {
    let workingDirectory: String
    let command: String?
    var onClosed: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalView {
        // Ensure the global app controller is initialized
        GhosttyAppController.shared.initialize()

        let view = GhosttyTerminalView(
            workingDirectory: workingDirectory,
            command: command
        )
        view.onSurfaceClosed = onClosed
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Nothing to update dynamically for now
    }
}

#endif // USE_GHOSTTY
