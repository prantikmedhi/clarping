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
        ClarpingApp.main()
    }
}

struct ClarpingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState(paths: .real)

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
                .onAppear { delegate.state = state }
        } label: {
            MenuBarLabel().environmentObject(state)
                .onAppear { delegate.attach(state) }
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
    var state: AppState?
    private var started = false

    func attach(_ s: AppState) {
        guard !started else { return }
        started = true
        state = s
        WindowManager.shared.state = s
        s.start()
        if ProcessInfo.processInfo.environment["CLARPING_DEBUG_SHOW"] == "1" {
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

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == window else { return }
        if preview == nil || preview?.isVisible == false { NSApp.setActivationPolicy(.accessory) }
    }

    /// Debug only: writes PNGs of the main window, popover preview and menu bar label.
    func snapshot(to dir: String, suffix: String) {
        if let state {
            let r = ImageRenderer(content: MenuBarLabel().environmentObject(state).padding(6).background(Color(nsColor: .windowBackgroundColor)))
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
