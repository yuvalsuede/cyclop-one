import AppKit
import SwiftUI

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

        setupStatusBarItem()
        setupFloatingDot()
        setupHotkey()
        setupExternalCommandListener()

        // Sprint 18 fix: Load skills at startup so SkillLoader.matchSkills()
        // has a populated skills array when Orchestrator.startRun() calls it.
        Task { await SkillLoader.shared.loadAll() }

        // Load plugins and start watching for changes
        Task {
            await PluginLoader.shared.loadAll()
            await PluginLoader.shared.startWatching()
        }

        // Bootstrap the Obsidian memory vault (create directory structure + seed files)
        Task { await MemoryService.shared.bootstrap() }

        checkFirstLaunch()

        // Sprint 16: Run retention cleanup in the background on launch
        performLaunchCleanup()

        // Sprint 16: Check for incomplete runs and offer to resume
        checkForIncompleteRuns()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            self?.handleHotkeyEvent(event)
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

        // Escape (no modifiers) — emergency stop running task
        if event.keyCode == 0x35 && flags.isEmpty {
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
    private func checkForIncompleteRuns() {
        Task {
            let incompleteRunIds = RunJournal.findIncompleteRuns()
            guard !incompleteRunIds.isEmpty else { return }

            NSLog("CyclopOne: Found \(incompleteRunIds.count) incomplete run(s) on launch.")

            for runId in incompleteRunIds {
                // Check if the run is stale
                if RunJournal.isRunStale(runId: runId) {
                    // Replay state BEFORE marking abandoned to avoid redundant replay
                    let state = RunJournal.replayRunState(runId: runId)
                    RunJournal.markAbandoned(runId: runId)
                    if let state = state {
                        let msg = "Abandoned stale task: \(state.command) (interrupted >1 hour ago)."
                        NSLog("CyclopOne: \(msg)")
                        await MainActor.run {
                            self.agentCoordinator.messages.append(
                                ChatMessage(role: .system, content: msg)
                            )
                        }
                    }
                    continue
                }

                // Recent incomplete run — attempt to resume
                guard let replayedState = RunJournal.replayRunState(runId: runId) else {
                    continue
                }

                let resumeMsg = "Resuming interrupted task: \(replayedState.command) (step \(replayedState.iterationCount))..."
                NSLog("CyclopOne: \(resumeMsg)")

                await MainActor.run {
                    self.agentCoordinator.messages.append(
                        ChatMessage(role: .system, content: resumeMsg)
                    )
                }

                // Resume via the Orchestrator with local reply channel
                let replyChannel: (any ReplyChannel)? = await LocalReplyChannel(coordinator: agentCoordinator)

                let result = await agentCoordinator.resumeIncompleteRun(
                    runId: runId,
                    replyChannel: replyChannel
                )

                if let result = result {
                    let statusText = result.success ? "completed successfully" : "failed: \(result.summary)"
                    let doneMsg = "Resumed task \(statusText). (\(result.iterations) iterations)"
                    NSLog("CyclopOne: \(doneMsg)")
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
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
            }
            .environmentObject(agentCoordinator)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
    }
}
