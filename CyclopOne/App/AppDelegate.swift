import AppKit
import SwiftUI

/// Set this to `true` immediately before posting a CGEvent key press from agent tools,
/// and back to `false` after. The global Escape hotkey monitor checks this flag to
/// avoid treating agent-synthesised Escape key events as emergency-stop requests.
/// (CGEvent.post(tap: .cghidEventTap) DOES fire NSEvent global monitors — the previous
/// assumption that it wouldn't was incorrect.)
nonisolated(unsafe) var agentIsPressingKeys: Bool = false

/// Main application delegate. Manages the floating dot, status bar item,
/// global hotkey, and coordinates all services.
///
/// Sprint 20: Removed FloatingPanel/ChatPanelView references.
/// The FloatingDot is now the sole persistent UI surface.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var floatingDot: FloatingDot?
    private var statusBarItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    let agentCoordinator = AgentCoordinator()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request screen capture access early — triggers the system prompt
        // if not yet granted, and validates existing permission.
        CGRequestScreenCaptureAccess()

        // Log accessibility permission status for debugging
        let axTrusted = AXIsProcessTrusted()
        NSLog("CyclopOne [AppDelegate]: AXIsProcessTrusted() = %@", axTrusted ? "YES ✓" : "NO ❌ — interaction tools will fail!")
        if !axTrusted {
            // Prompt user to grant accessibility
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        // Pre-request Automation permission for System Events (needed for open_url AppleScript via Chrome).
        // Running this at launch triggers the macOS permission prompt early so the agent never
        // hits a "Permission denied: wants to send Apple events" error mid-run.
        Task.detached {
            let script = NSAppleScript(source: "tell application \"System Events\" to return name of first process")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }

        // Start network reachability monitor
        Task { await NetworkMonitor.shared.start() }

        setupStatusBarItem()
        setupFloatingDot()
        setupHotkey()
        setupExternalCommandListener()

        // SkillRegistry is the unified loader — replaces both SkillLoader and PluginLoader.
        Task { await SkillRegistry.shared.loadAll() }

        // Bootstrap the Obsidian memory vault (create directory structure + seed files)
        Task {
            await MemoryService.shared.bootstrap()
            await MemoryService.shared.startSession()
        }

        // Bootstrap procedural memory store
        Task {
            await ProceduralMemoryService.shared.bootstrap()
        }

        // Enable vision-first reactive loop
        if !UserDefaults.standard.bool(forKey: "reactiveLoopConfigured") {
            UserDefaults.standard.set(true, forKey: "useReactiveLoop")
            UserDefaults.standard.set(true, forKey: "reactiveLoopConfigured")
        }

        checkFirstLaunch()

        // Start Telegram bot if token is configured (load token here to avoid
        // blocking the TelegramService actor with SecItemCopyMatching)
        let telegramGW = agentCoordinator.gateway
        Task.detached {
            let token = KeychainService.shared.getTelegramToken()
            await TelegramService.shared.start(gateway: telegramGW, token: token)
        }

        // Sprint 16: Run retention cleanup in the background on launch
        performLaunchCleanup()

        // Sprint 16: Check for incomplete runs and offer to resume
        checkForIncompleteRuns()

        // Check for app updates (throttled to once per 24 hours)
        Task { await UpdateChecker.shared.checkOnLaunch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cancel any running agent tasks before quitting
        agentCoordinator.cancel()
        // Finalize vault session note
        let tokens = agentCoordinator.totalTokensUsed
        Task { await MemoryService.shared.endSession(totalRuns: 0, successCount: 0, totalTokens: tokens) }
        // Stop network monitor
        Task { await NetworkMonitor.shared.stop() }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    // MARK: - Status Bar

    private func setupStatusBarItem() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusBarItem?.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Cyclop One")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Run Onboarding Again", action: #selector(showOnboardingMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Cyclop One", action: #selector(quitApp), keyEquivalent: "q"))
        statusBarItem?.menu = menu
    }

    // MARK: - Floating Dot (Sprint 5)

    private func setupFloatingDot() {
        let dot = FloatingDot(coordinator: agentCoordinator)
        floatingDot = dot
        // Wire the dot reference back to the coordinator for direct updates
        agentCoordinator.setFloatingDot(dot)
        // Dot is the default UI — show it immediately
        dot.orderFront(nil)

        // Sprint 7: Register Cyclop One window IDs for screenshot exclusion
        registerExcludedWindows()
    }

    /// Sprint 7: Tell ScreenCaptureService which windows belong to Cyclop One
    /// so they are excluded from screenshots.
    private func registerExcludedWindows() {
        var windowIDs = Set<CGWindowID>()
        if let dotNum = floatingDot?.windowNumber, dotNum > 0 {
            windowIDs.insert(CGWindowID(dotNum))
        }
        Task {
            await ScreenCaptureService.shared.setExcludedWindowIDs(windowIDs)
        }
    }

    // MARK: - Global Hotkey (Cmd+Shift+A)

    private func setupHotkey() {
        // Monitor when our app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalHotkeyEvent(event)
        }
        // Monitor when our app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleHotkeyEvent(event) == true {
                return nil // Consume the event
            }
            return event
        }
    }

    @discardableResult
    private func handleHotkeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Shift+A — toggle popover
        if flags == [.command, .shift] && event.keyCode == 0x00 { // 'A' key
            DispatchQueue.main.async { [weak self] in
                self?.toggleDotPopover()
            }
            return true
        }

        // Escape (no modifiers) — emergency stop for any active state.
        // This local monitor only fires when CyclopOne itself is focused.
        // During automation, the target app (e.g. Chrome) is frontmost, so
        // the agent's CGEvent key presses go there, not here.
        // Guard: ignore if the agent itself is currently posting a key event.
        if event.keyCode == 0x35 && flags.isEmpty && !agentIsPressingKeys {
            if agentCoordinator.state.isActive {
                DispatchQueue.main.async { [weak self] in
                    self?.agentCoordinator.cancel()
                    NSLog("CyclopOne [AppDelegate]: Emergency stop via Escape key")
                }
                return true
            }
        }

        return false
    }

    @discardableResult
    private func handleGlobalHotkeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd+Shift+A — toggle popover
        if flags == [.command, .shift] && event.keyCode == 0x00 {
            DispatchQueue.main.async { [weak self] in
                self?.toggleDotPopover()
            }
            return true
        }
        // Escape (no modifiers) — global emergency stop.
        // This fires when any OTHER app is frontmost (Chrome, etc).
        // NOTE: CGEvent.post(tap: .cghidEventTap) DOES fire this global monitor,
        // so we must guard against the agent's own synthesised Escape key events
        // to avoid treating them as user-initiated emergency stops.
        if event.keyCode == 0x35 && flags.isEmpty && !agentIsPressingKeys {
            if agentCoordinator.state.isActive {
                DispatchQueue.main.async { [weak self] in
                    self?.agentCoordinator.cancel()
                    NSLog("CyclopOne [AppDelegate]: Emergency stop via global Escape key")
                }
                return true
            }
        }
        return false
    }

    /// Toggle the floating dot popover (replaces panel toggle).
    private func toggleDotPopover() {
        guard let dot = floatingDot else { return }
        dot.togglePopover()
    }

    // MARK: - External Command Listener

    /// Listen for commands from external processes via DistributedNotificationCenter.
    /// Usage from CLI: swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("com.cyclop.one.command"), object: nil, userInfo: ["action": "run", "command": "open Calculator"])'
    private func setupExternalCommandListener() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExternalNotification(_:)),
            name: NSNotification.Name("com.cyclop.one.command"),
            object: nil
        )
        NSLog("CyclopOne [AppDelegate]: External command listener registered.")
    }

    @objc private func handleExternalNotification(_ notification: Notification) {
        let action = notification.userInfo?["action"] as? String ?? "toggle"
        let command = notification.userInfo?["command"] as? String

        NSLog("CyclopOne [AppDelegate]: External notification action=%@ command=%@",
              action, command ?? "(none)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case "toggle":
                self.toggleDotPopover()
            case "run":
                if let command = command, !command.isEmpty {
                    Task {
                        await self.agentCoordinator.handleUserMessage(command)
                    }
                }
            case "setkey":
                if let key = command, !key.isEmpty {
                    let success = KeychainService.shared.setAPIKey(key)
                    NSLog("CyclopOne [AppDelegate]: setkey result=%@", success ? "OK" : "FAIL")
                    if success {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        // Don't close the onboarding window programmatically —
                        // it causes EXC_BAD_ACCESS when SwiftUI hosting view is
                        // released. The window is harmless and will be gone on
                        // next launch.
                    }
                }
            case "settelegram":
                if let token = command, !token.isEmpty {
                    let success = KeychainService.shared.setTelegramToken(token)
                    NSLog("CyclopOne [AppDelegate]: settelegram result=%@", success ? "OK" : "FAIL")
                    if success {
                        let gw = self.agentCoordinator.gateway
                        let tok = token
                        Task.detached {
                            await TelegramService.shared.start(gateway: gw, token: tok)
                        }
                    }
                }
            case "stop":
                NSLog("CyclopOne [AppDelegate]: External stop request")
                self.agentCoordinator.cancel()
            case "status":
                let state = self.agentCoordinator.state
                let axTrusted = AXIsProcessTrusted()
                let screenOk = CGPreflightScreenCaptureAccess()
                NSLog("CyclopOne [Status]: state=%@ ax=%@ screen=%@",
                      String(describing: state),
                      axTrusted ? "YES" : "NO",
                      screenOk ? "YES" : "NO")
            default:
                self.toggleDotPopover()
            }
        }
    }

    // MARK: - Sprint 16: Crash Recovery & Run Retention

    /// Run retention cleanup in the background on launch.
    private func performLaunchCleanup() {
        Task.detached(priority: .utility) {
            let deleted = RunJournal.cleanupOldRuns()
            if deleted > 0 {
                NSLog("CyclopOne: Cleaned up \(deleted) old run(s) on launch.")
            }
        }
    }

    /// Check for incomplete runs from a previous session (crash recovery).
    /// All incomplete runs are marked abandoned on startup — the Mac's state
    /// has changed since the crash, making resume unreliable.
    private func checkForIncompleteRuns() {
        Task {
            let incompleteRunIds = RunJournal.findIncompleteRuns()
            guard !incompleteRunIds.isEmpty else { return }

            NSLog("CyclopOne: Found %d incomplete run(s) on launch — marking all as abandoned.", incompleteRunIds.count)

            for runId in incompleteRunIds {
                let state = RunJournal.replayRunState(runId: runId)
                RunJournal.markAbandoned(runId: runId)

                if let state = state {
                    let msg = "Previous task interrupted: \(state.command) (was at step \(state.iterationCount)). Marked abandoned."
                    NSLog("CyclopOne: %@", msg)
                    await MainActor.run {
                        self.agentCoordinator.messages.append(
                            ChatMessage(role: .system, content: msg)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func checkForUpdatesMenu() {
        Task { await UpdateChecker.shared.checkNow() }
    }

    @objc func openSettings() {
        // For LSUIElement agent apps showSettingsWindow: is unreliable.
        // Manage the settings window directly instead.
        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(agentCoordinator)

        let controller = NSHostingController(rootView: settingsView)
        let win = NSWindow(contentViewController: controller)
        win.title = "Cyclop One Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 520, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func showOnboardingMenu() {
        showOnboarding()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - First Launch

    private func checkFirstLaunch() {
        let hasLaunched = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasLaunched {
            NSLog("CyclopOne [AppDelegate]: First launch — showing onboarding")
            showOnboarding()
            return
        }
        // Check API key on a background thread to avoid blocking the main
        // thread if SecItemCopyMatching needs to talk to securityd (which
        // happens when the Keychain item was created by a different binary).
        DispatchQueue.global(qos: .userInitiated).async {
            let hasKey = KeychainService.shared.getAPIKey() != nil
            if !hasKey {
                NSLog("CyclopOne [AppDelegate]: API key missing. Set it via: /tmp/send_command setkey \"YOUR_KEY\"")
            } else {
                NSLog("CyclopOne [AppDelegate]: API key present. Ready.")
            }
        }
    }

    private func showOnboarding() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Welcome to Cyclop One"
        window.level = .floating
        window.contentView = NSHostingView(
            rootView: OnboardingView { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                // Hide instead of close — closing the NSHostingView
                // during autorelease causes EXC_BAD_ACCESS.
                self?.onboardingWindow?.orderOut(nil)
                self?.floatingDot?.orderFront(nil)

                // Start TelegramService if a token was saved during onboarding
                if let self = self {
                    let telegramGW = self.agentCoordinator.gateway
                    Task.detached {
                        let token = KeychainService.shared.getTelegramToken()
                        if token != nil {
                            await TelegramService.shared.start(gateway: telegramGW, token: token)
                        }
                    }
                }
            }
            .environmentObject(agentCoordinator)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }
}
