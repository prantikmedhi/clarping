import SwiftUI
import AppKit
import Combine

@main
enum Entry {
    private static var delegate: AppDelegate?

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
        // Plain AppKit lifecycle: the status item and its popover are AppKit
        // objects (see StatusItemController). SwiftUI's MenuBarExtra re-hosted
        // and re-rendered its label on every scene update, which spun the main
        // thread whenever the label or the open popover changed per frame.
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState(paths: .real)
    private(set) var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppDelegate.makeMenu()
        WindowManager.shared.state = state
        statusItem = StatusItemController(model: state.menuBar, content: PopoverView().environmentObject(state))
        WindowManager.shared.showPopover = { [weak self] in self?.statusItem?.show() }
        state.start()
        installDebugHooks()
        // First run: the setup guide, once. Re-openable from Settings.
        if !state.settings.onboardingDone, ProcessInfo.processInfo.environment["CLARPING_DEBUG_SHOT"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WindowManager.shared.showOnboarding() }
        }
    }

    @objc private func showSettings(_ sender: Any?) { WindowManager.shared.show(.settings) }

    /// App menu (Settings, Quit) and Edit menu so text fields get the standard
    /// shortcuts; the app is an accessory, so the menu is visible only while the
    /// main window is open.
    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clarping", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        return menu
    }

    /// Debug-only environment hooks (all off by default):
    /// CLARPING_DEBUG_OPEN_POPOVER=1  click the status item after 2 s.
    /// CLARPING_DEBUG_CONFIRM=1       open the switch-confirm panel on the first inactive account at 4 s (UI only).
    /// CLARPING_DEBUG_DRY_SWITCH=1    at 6 s show the switch-in-progress state for 30 s without touching
    ///                                keychain or files (no Switcher call is made).
    /// CLARPING_DEBUG_POLL_AT=<s>     run one real poll cycle <s> seconds after launch.
    /// CLARPING_DEBUG_SHOW=1          open the main window; CLARPING_DEBUG_ONBOARDING=1 opens the setup guide.
    /// CLARPING_DEBUG_SHOT=<dir>      writes PNGs: popover (3 s), popover with confirm (5 s, needs CONFIRM),
    ///                                dashboard (14 s), settings (17.5 s), each onboarding step (20 s + 1.5 s per step).
    private func installDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        let s = state
        if env["CLARPING_DEBUG_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                Debug.log("clicking status item")
                self?.statusItem?.item.button?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    Debug.log("popover shown=\(self?.statusItem?.popover.isShown ?? false) size=\(self?.statusItem?.popover.contentSize ?? .zero)")
                }
            }
        }
        if env["CLARPING_DEBUG_CONFIRM"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if let a = s.accounts.first(where: { $0.id != s.activeId }) { s.requestSwitch(to: a); Debug.log("confirm panel opened") }
            }
        }
        if env["CLARPING_DEBUG_DRY_SWITCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let a = s.accounts.first(where: { $0.id != s.activeId }) ?? s.accounts.first else { return }
                s.confirmTarget = nil
                s.switchingTo = a.id
                s.switchStep = .writingKeychain
                Debug.log("dry switch state ON")
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    s.switchingTo = nil
                    s.switchStep = nil
                    Debug.log("dry switch state OFF")
                }
            }
        }
        if let at = env["CLARPING_DEBUG_POLL_AT"].flatMap(Double.init) {
            // Run a real poll cycle at a known time (for example with the popover open).
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { Debug.log("debug poll start"); Task { await s.pollAll(); Debug.log("debug poll end") } }
        }
        if env["CLARPING_DEBUG_ONBOARDING"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WindowManager.shared.showOnboarding() }
        }
        if env["CLARPING_DEBUG_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WindowManager.shared.show(.dashboard) }
            if let dir = env["CLARPING_DEBUG_SHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.snapshot(to: dir, suffix: "popover") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.snapshot(to: dir, suffix: "popover-confirm") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.snapshot(to: dir, suffix: "dashboard") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) { [weak self] in
                    WindowManager.shared.show(.settings)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.snapshot(to: dir, suffix: "settings") }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 19) { WindowManager.shared.showOnboarding() }
                // Sequential (each capture takes a moment; absolute timers drifted past the next step).
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.captureOnboarding(step: 0, to: dir) }
            }
        }
    }

    /// Debug only: steps the setup guide and captures each page in turn.
    private func captureOnboarding(step: Int, to dir: String) {
        guard step < 7 else { return }
        state.onboardingStep = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.snapshot(to: dir, suffix: "onboarding-\(step + 1)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.captureOnboarding(step: step + 1, to: dir) }
        }
    }

    /// Debug only: writes PNGs. `<suffix>.png` is the view that step is about
    /// (popover*, dashboard / settings = main window, onboarding-N = setup
    /// guide), rendered with `cacheDisplay` (no real glass blur), plus
    /// `<suffix>-window.png` from `screencapture -l` of the real window when
    /// Screen Recording permission allows it. The status item image is written
    /// once as menubar.png.
    private func snapshot(to dir: String, suffix: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if suffix == "popover", let img = statusItem?.item.button?.image, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("menubar.png"))
        }
        let view: NSView?
        if suffix.hasPrefix("popover") { view = statusItem?.popover.contentViewController?.view }
        else if suffix.hasPrefix("onboarding") { view = WindowManager.shared.onboardingContentView }
        else { view = WindowManager.shared.windowContentView }
        guard let view else { Debug.log("snapshot \(suffix): no view"); return }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("\(suffix).png"))
            }
        }
        if let num = view.window?.windowNumber {
            let path = out.appendingPathComponent("\(suffix)-window.png").path
            // Off-main: screencapture can take a moment; nothing here touches app state.
            Task.detached(priority: .utility) {
                _ = try? Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(num), path])
            }
        }
    }
}

/// AppKit status item and popover. The button image is set only when one of
/// the three MenuBarModel values changes; the switch-in-progress cue is a
/// CoreAnimation opacity pulse on the button layer, never a per-frame
/// SwiftUI re-render. The popover hosts the SwiftUI PopoverView; all state it
/// shows lives in AppState, so a transient close (for example when Claude
/// Desktop relaunches and takes focus mid-switch) loses nothing.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private var sinks = Set<AnyCancellable>()

    init<Content: View>(model: MenuBarModel, content: Content) {
        super.init()
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.imagePosition = .imageOnly
            b.toolTip = "Clarping"
        }
        model.$fill.combineLatest(model.$text, model.$switching)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] fill, text, switching in self?.apply(fill: fill, text: text, switching: switching) }
            .store(in: &sinks)
    }

    private func apply(fill: Int?, text: String?, switching: Bool) {
        guard let b = item.button else { return }
        Debug.log("status item image update fill=\(fill.map(String.init) ?? "-") switching=\(switching)")
        b.image = SparkIcon.labelImage(fill: fill, text: text, switching: switching)
        b.wantsLayer = true
        if switching, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if b.layer?.animation(forKey: "pulse") == nil {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1.0
                a.toValue = 0.4
                a.duration = 0.7
                a.autoreverses = true
                a.repeatCount = .infinity
                b.layer?.add(a, forKey: "pulse")
            }
        } else {
            b.layer?.removeAnimation(forKey: "pulse")
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { show() }
    }

    func show() {
        guard let b = item.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }
}

/// Owns the main window (dashboard + settings) and flips the activation policy
/// so the app has a Dock icon and menu bar only while that window is open.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    var state: AppState?
    private var window: NSWindow?
    private var onboarding: NSWindow?
    var windowContentView: NSView? { window?.contentView }
    var onboardingContentView: NSView? { onboarding?.contentView }
    /// Opens the menu bar popover (set by AppDelegate; used by the setup guide).
    var showPopover: (() -> Void)?

    /// The first-run setup guide; one fixed-size window, re-shown on request.
    func showOnboarding() {
        guard let state else { return }
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Clarping Setup"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.contentView = NSHostingView(rootView: OnboardingView().environmentObject(state))
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            onboarding = w
        }
        NSApp.setActivationPolicy(.regular)
        onboarding?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() { onboarding?.close() }

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
        guard let closing = notification.object as? NSWindow, closing == window || closing == onboarding else { return }
        if closing == onboarding { state?.finishOnboarding() }
        let other = closing == window ? onboarding : window
        if other?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
    }
}

/// CLARPING_DEBUG_CHANGES=1 prints which views re-render and why (stderr).
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
