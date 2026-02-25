import Foundation
import AppKit

/// Manages the Cyclop One floating panel's visibility and focus during agent operations.
///
/// Extracted from AgentLoop (Sprint refactor) to separate UI concerns from agent logic.
/// Handles:
/// - Hiding/showing panel for clean screenshots
/// - Mouse event passthrough for click/drag actions
/// - Target app activation and verification
/// - Coordinate mapping from screenshot to screen space
actor WindowManager {

    /// Weak reference to the floating dot panel.
    private weak var panel: NSPanel?

    /// Weak reference to FloatingDot (needed for popover dismissal and window enumeration).
    private weak var floatingDot: FloatingDot?

    /// Screen capture service — needed to set excluded window IDs.
    private let captureService: ScreenCaptureService

    /// Whether the panel is currently hidden (avoids redundant hide/show cycles).
    private var panelIsHidden = false

    /// The PID of the target app the agent should be interacting with.
    private(set) var targetAppPID: pid_t?

    init(captureService: ScreenCaptureService = .shared) {
        self.captureService = captureService
    }

    func setPanel(_ panel: NSPanel) {
        self.panel = panel
    }

    func setFloatingDot(_ dot: FloatingDot) {
        self.floatingDot = dot
        self.panel = dot  // FloatingDot IS the NSPanel
    }

    func setTargetAppPID(_ pid: pid_t?) {
        self.targetAppPID = pid
    }

    // MARK: - Screenshot Visibility

    /// Fully hide all Cyclop One windows for clean screenshots.
    ///
    /// 1. Dismiss the popover (separate NSWindow created by NSPopover).
    /// 2. Collect all Cyclop One window numbers and update ScreenCaptureService exclusion list.
    /// 3. Hide the floating dot panel.
    /// 4. Sleep for the window server to process the hide.
    /// 5. Wait/poll until all Cyclop One windows are gone from the on-screen window list.
    /// 6. Verify and log that no Cyclop One windows remain.
    func hideForScreenshot() async {
        if panelIsHidden { return }

        // Step 1: Dismiss popover and collect all window IDs BEFORE hiding
        let windowNumbers = await MainActor.run { [floatingDot] () -> [Int] in
            floatingDot?.dismissPopover()
            return floatingDot?.allWindowNumbers() ?? []
        }

        // Step 2: Update excluded window IDs in ScreenCaptureService for the SCKit path
        let excludedIDs = Set(windowNumbers.map { CGWindowID($0) })
        await captureService.setExcludedWindowIDs(excludedIDs)

        // Step 3: Hide the floating dot panel
        await MainActor.run { [panel] in
            panel?.orderOut(nil)
        }

        // Step 4: Brief delay for the window server to process the hide
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Step 5: Poll until all Cyclop One windows are gone (up to 200ms)
        await waitForWindowsHidden(windowNumbers: windowNumbers, timeout: 200_000_000)

        panelIsHidden = true

        // Step 6: Verify no Cyclop One windows remain
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let knownWindowSet = Set(windowNumbers)
        let ourVisibleWindows = windowList.filter { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == ourPID else { return false }
            guard let num = info[kCGWindowNumber as String] as? Int else { return false }
            return knownWindowSet.contains(num)
        }
        if ourVisibleWindows.isEmpty {
            NSLog("CyclopOne [WindowManager]: Verified -- tracked windows hidden (PID %d)", ourPID)
        } else {
            let windowNums = ourVisibleWindows.compactMap { $0[kCGWindowNumber as String] as? Int }
            NSLog("CyclopOne [WindowManager]: WARNING -- %d tracked windows still visible (PID %d): %@",
                  ourVisibleWindows.count, ourPID, windowNums.map { String($0) }.joined(separator: ", "))
        }
    }

    /// Poll until none of the given window numbers are visible, or timeout.
    private func waitForWindowsHidden(windowNumbers: [Int], timeout: UInt64) async {
        guard !windowNumbers.isEmpty else { return }
        let windowSet = Set(windowNumbers)

        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let anyStillVisible = windowList.contains { info in
                guard let num = info[kCGWindowNumber as String] as? Int else { return false }
                return windowSet.contains(num)
            }
            if !anyStillVisible { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// Bring panel back after screenshot -- DON'T steal keyboard focus.
    func showAfterScreenshot() async {
        await MainActor.run { [panel] in
            panel?.orderFront(nil)
        }
        panelIsHidden = false
    }

    // MARK: - Click Passthrough

    /// Make panel transparent to mouse events (for clicks/drags/scrolls).
    func letClicksThrough() async {
        await MainActor.run { [panel] in
            panel?.ignoresMouseEvents = true
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }

    /// Restore panel mouse event handling.
    func stopClicksThrough() async {
        await MainActor.run { [panel] in
            panel?.ignoresMouseEvents = false
        }
    }

    // MARK: - Target App Activation

    /// Ensure the target application (not Cyclop One) has keyboard focus.
    func activateTargetApp() async {
        let savedPID = self.targetAppPID
        await MainActor.run { [panel] in
            let currentPID = ProcessInfo.processInfo.processIdentifier

            panel?.ignoresMouseEvents = true
            NSApp.deactivate()

            // Try to activate the saved target app
            if let pid = savedPID,
               let app = NSRunningApplication(processIdentifier: pid),
               !app.isTerminated {
                app.activate(options: .activateIgnoringOtherApps)
                return
            }

            // Fallback: activate the frontmost non-Cyclop One app
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != currentPID {
                front.activate(options: .activateIgnoringOtherApps)
                return
            }

            // Last resort: find any regular app
            if let target = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular &&
                $0.processIdentifier != currentPID &&
                !$0.isTerminated &&
                !$0.isHidden
            }) {
                target.activate(options: .activateIgnoringOtherApps)
            }
        }

        // Poll to verify activation succeeded (up to 500ms)
        await verifyActivation(expectedPID: savedPID, timeout: 500_000_000)
    }

    /// Poll frontmostApplication every 50ms to confirm the target app is active.
    private func verifyActivation(expectedPID: pid_t?, timeout: UInt64) async {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let frontPID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }

            if let front = frontPID, front != currentPID {
                if let expected = expectedPID, front == expected {
                    return
                }
                if expectedPID == nil {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - Panel Restoration

    /// Re-enable the panel for user interaction (called when agent finishes).
    func restorePanelInteraction() async {
        await MainActor.run { [panel] in
            panel?.ignoresMouseEvents = false
            panel?.orderFront(nil)
        }
        panelIsHidden = false
    }

    // MARK: - Target PID Update

    /// Update targetAppPID from the current frontmost application.
    func updateTargetPID() async {
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms for activation
        let newPID = await MainActor.run { () -> pid_t? in
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != currentPID {
                return front.processIdentifier
            }
            return nil
        }
        if let pid = newPID {
            targetAppPID = pid
        }
    }
}
