import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dry-run-selftest"), i + 1 < args.count {
            exit(SelfTest.run(home: URL(fileURLWithPath: args[i + 1])))
        }
        if args.contains("--add-current") {
            // Headless capture of the active login into Clarping's vault (read-only w.r.t. Claude's files).
            let vault = Vault(paths: .real)
            var accounts = vault.loadAccounts()
            let sw = Switcher(paths: .real, vault: vault)
            sw.identityCheck = { try await ClaudeAPI.profile(token: $0).accountId }
            var code: Int32 = 1
            var done = false
            // Detached: main() is main-actor bound and keeps the main run loop
            // turning below (URLSession needs it in a headless process).
            Task.detached {
                do {
                    if let id = sw.currentAccountUUID(), let existing = accounts.first(where: { $0.id == id }), !args.contains("--relink") {
                        print("\(existing.label) is already linked. Log in to another account with `claude /login` first, then run --add-current again (or pass --relink to re-capture).")
                        code = 3
                        done = true
                        return
                    }
                    let a = try await sw.captureCurrent(into: &accounts, desktop: .skipIfRunning)
                    vault.saveAccounts(accounts)
                    print("captured \(a.label) (\(a.emailDomain))")
                    if let note = sw.lastCaptureNote { print("note: \(note)") }
                    code = 0
                } catch {
                    print("failed: \(error.localizedDescription)")
                }
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
            exit(code)
        }
        if Debug.changes { setlinebuf(stdout) }
        ClarpingApp.main()
    }
}

struct ClarpingApp: App {
    // The delegate owns AppState and is not an ObservableObject, so the scene
    // body (and with it the MenuBarExtra button) is not re-evaluated on every
    // published change; only the views that read AppState re-render.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(delegate.state)
        } label: {
            MenuBarLabel(model: delegate.state.menuBar)
                .onAppear { delegate.attach() }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { WindowManager.shared.show(.settings) }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState(paths: .real)
    private var started = false

    func attach() {
        guard !started else { return }
        started = true
        let s = state
        WindowManager.shared.state = s
        s.start()
        let env = ProcessInfo.processInfo.environment
        // CLARPING_DEBUG_OPEN_POPOVER=1: click the status item after launch (reproduces the
        // open-popover state headlessly). CLARPING_DEBUG_CONFIRM=1: also open the
        // switch-confirm panel on the first inactive account (UI only, no switch).
        if env["CLARPING_DEBUG_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { WindowManager.clickStatusItem() }
        }
        if env["CLARPING_DEBUG_CONFIRM"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let a = s.accounts.first(where: { $0.id != s.activeId }) { s.requestSwitch(to: a) }
            }
        }
        if env["CLARPING_DEBUG_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WindowManager.shared.show(.dashboard)
                WindowManager.shared.showPopoverPreview()
            }
            // CLARPING_DEBUG_SHOT=<dir>: render each window to PNG after data has loaded.
            if let dir = ProcessInfo.processInfo.environment["CLARPING_DEBUG_SHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { WindowManager.shared.snapshot(to: dir, suffix: "dashboard") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
                    WindowManager.shared.show(.settings)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WindowManager.shared.snapshot(to: dir, suffix: "settings") }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the main window (dashboard + settings) and flips the activation policy
/// so the app has a Dock icon and menu bar only while that window is open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    var state: AppState?
    private var window: NSWindow?
    private var preview: NSWindow?

    func show(_ tab: MainTab) {
        guard let state else { return }
        state.mainTab = tab
        if window == nil {
            let tall = ProcessInfo.processInfo.environment["CLARPING_DEBUG_SHOT"] != nil
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: tall ? 1180 : 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Clarping"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.minSize = NSSize(width: 640, height: 440)
            w.contentView = NSHostingView(rootView: MainWindow().environmentObject(state))
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Debug only: presses the MenuBarExtra status item button.
    static func clickStatusItem() {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        for w in NSApp.windows {
            guard let cv = w.contentView, let b = find(cv) else { continue }
            // A real mouse down/up through NSApp.sendEvent, so the MenuBarExtra
            // controller sees a click event (performClick alone does not open the window).
            let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
            Debug.log("clicking status item at window point \(p) frame \(w.frame)")
            func ev(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
            }
            if let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) {
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Debug.log("windows: " + NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; "))
                if ProcessInfo.processInfo.environment["CLARPING_DEBUG_HOVER"] == "1" { startSyntheticHover() }
            }
            return
        }
        Debug.log("status item button not found")
    }

    /// Debug only: streams mouseMoved events across the open popover window
    /// (the largest visible non-status window) to stand in for a hovering pointer.
    static func startSyntheticHover() {
        guard let w = NSApp.windows.filter({ $0.isVisible && !($0 is NSPanel && $0.frame.height < 30) && String(describing: type(of: $0)) != "NSStatusBarWindow" })
                .max(by: { $0.frame.height < $1.frame.height }) else { Debug.log("hover: no popover window"); return }
        Debug.log("hover: over \(type(of: w)) \(w.frame)")
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            i += 1
            let x = CGFloat(20 + (i * 7) % max(1, Int(w.frame.width) - 40))
            let y = CGFloat(20 + (i * 11) % max(1, Int(w.frame.height) - 40))
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: i, clickCount: 0, pressure: 0) {
                NSApp.sendEvent(e)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == window else { return }
        if preview == nil || preview?.isVisible == false { NSApp.setActivationPolicy(.accessory) }
    }

    /// Debug only: writes PNGs of the main window, popover preview and menu bar label.
    func snapshot(to dir: String, suffix: String) {
        if let state {
            let r = ImageRenderer(content: MenuBarLabel(model: state.menuBar).padding(6).background(Color(nsColor: .windowBackgroundColor)))
            r.scale = 4
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-\(suffix).png"))
            }
        }
        for (w, name) in [(window, "main-\(suffix)"), (preview, "popover-\(suffix)")] {
            guard let v = w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }

    /// Debug only: hosts the popover content in a plain window so it can be captured.
    func showPopoverPreview() {
        guard let state else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Popover preview"
        w.contentView = NSHostingView(rootView: PopoverView().environmentObject(state))
        w.setFrameTopLeftPoint(NSPoint(x: 60, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 20))
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        preview = w
    }
}

/// CLARPING_DEBUG_CHANGES=1 prints which views re-render and why (stdout).
enum Debug {
    static let changes = ProcessInfo.processInfo.environment["CLARPING_DEBUG_CHANGES"] == "1"
    static var counts: [String: Int] = [:]
    static let t0 = Date()
    static func log(_ s: String) {
        guard changes else { return }
        FileHandle.standardError.write(Data((String(format: "[%8.3f] ", Date().timeIntervalSince(t0)) + s + "\n").utf8))
    }
    static func tick(_ name: String) {
        guard changes else { return }
        counts[name, default: 0] += 1
        let n = counts[name]!
        if n <= 20 || n % 100 == 0 { log("render \(name) #\(n)") }
    }
}
