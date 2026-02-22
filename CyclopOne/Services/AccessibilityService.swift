import Foundation
import AppKit
import ApplicationServices

/// Reads the UI accessibility tree and performs UI actions (click, type) via AXUIElement.
/// Marked @MainActor to ensure thread safety: AXUIElement operations must be called
/// from the main thread per Apple's Accessibility API requirements.
@MainActor
class AccessibilityService {

    static let shared = AccessibilityService()

    private init() {}

    // MARK: - Permission Check

    /// Check if Accessibility permission is granted.
    func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Read UI Tree

    /// Get a summary of the focused application's UI tree.
    func getFocusedAppUITree(maxDepth: Int = 4) -> UITreeNode? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return readElement(appElement, depth: 0, maxDepth: maxDepth)
    }

    /// Get the UI tree for a specific application by PID.
    func getUITreeForPID(_ pid: pid_t, maxDepth: Int = 4) -> UITreeNode? {
        let appElement = AXUIElementCreateApplication(pid)
        return readElement(appElement, depth: 0, maxDepth: maxDepth)
    }

    /// Get a text summary suitable for sending to Claude.
    /// If `targetPID` is provided, reads that app's UI tree instead of the frontmost app.
    /// This prevents accidentally reading Cyclop One's own UI when the panel regains focus.
    func getUITreeSummary(targetPID: pid_t? = nil, maxDepth: Int = 6) -> String {
        let app: NSRunningApplication?
        let pid: pid_t

        if let targetPID = targetPID,
           let targetApp = NSRunningApplication(processIdentifier: targetPID),
           !targetApp.isTerminated {
            app = targetApp
            pid = targetPID
        } else {
            // Fallback to frontmost, but skip Cyclop One itself
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let frontApp = NSWorkspace.shared.frontmostApplication
            if let frontApp = frontApp, frontApp.processIdentifier != currentPID {
                app = frontApp
                pid = frontApp.processIdentifier
            } else {
                // Frontmost IS Cyclop One — find the next best candidate
                let candidate = NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular &&
                    $0.processIdentifier != currentPID &&
                    !$0.isTerminated &&
                    !$0.isHidden
                })
                if let candidate = candidate {
                    app = candidate
                    pid = candidate.processIdentifier
                } else {
                    return "No target application found."
                }
            }
        }

        let appName = app?.localizedName ?? "Unknown"
        var summary = "Target App: \(appName) (pid: \(pid))\n"

        guard let tree = getUITreeForPID(pid, maxDepth: maxDepth) else {
            let axTrusted = AXIsProcessTrusted()
            NSLog("CyclopOne [AccessibilityService]: Could not read UI tree for %@ (pid=%d), AXIsProcessTrusted=%@",
                  appName, pid, axTrusted ? "YES" : "NO")
            if !axTrusted {
                return summary + "Could not read UI tree. ERROR: Accessibility permission not granted. The agent cannot read UI elements. Grant permission in System Settings > Privacy & Security > Accessibility."
            }
            return summary + "Could not read UI tree."
        }

        summary += formatNode(tree, indent: 0)
        // Truncate if too long (keep under ~6000 chars for token efficiency)
        // Increased from 4000 to 6000 to accommodate deeper trees (maxDepth=6)
        if summary.count > 6000 {
            summary = String(summary.prefix(5900)) + "\n… (truncated)"
        }

        NSLog("CyclopOne [AccessibilityService]: UI tree for %@ (pid=%d), length=%d chars: %@",
              appName, pid, summary.count, String(summary.prefix(500)))
        return summary
    }

    // MARK: - App Focus Management (Sprint 7)

    /// Get the current frontmost application.
    func getFrontmostApp() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    /// Activate a specific app by its bundle identifier.
    /// Returns true if the app was found and activation was requested.
    @discardableResult
    func activateApp(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else {
            return false
        }
        return app.activate(options: .activateIgnoringOtherApps)
    }

    /// Activate a specific app by its process identifier.
    /// Returns true if the app was found and activation was requested.
    @discardableResult
    func activateApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            return false
        }
        return app.activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - Actions

    /// Result type for interaction actions — reports whether the event was actually posted.
    struct ActionResult: Sendable {
        let success: Bool
        let error: String?

        static let ok = ActionResult(success: true, error: nil)
        static func failed(_ msg: String) -> ActionResult { ActionResult(success: false, error: msg) }
    }

    /// Pre-flight warning: log if Accessibility is not enabled.
    /// NOTE: CGEvent creation and posting works WITHOUT AXIsProcessTrusted.
    /// AX permission is only required for reading UI trees (AXUIElement APIs).
    /// We warn but do NOT block CGEvent-based actions.
    private func preflightWarn(_ action: String) {
        if !AXIsProcessTrusted() {
            NSLog("CyclopOne [AccessibilityService]: ⚠️ %@ — AXIsProcessTrusted() is false. UI tree reading will fail, but CGEvents may still work.", action)
        }
    }

    /// Click a UI element at the given screen coordinates.
    @discardableResult
    func clickAt(x: Double, y: Double) -> ActionResult {
        preflightWarn("clickAt(\(Int(x)),\(Int(y)))")
        let point = CGPoint(x: x, y: y)

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ clickAt — CGEvent creation returned nil")
            return .failed("CGEvent creation failed for click — accessibility permission may not be fully active. Try toggling Accessibility off and on in System Settings.")
        }

        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms delay
        mouseUp.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ clickAt(%d,%d) posted", Int(x), Int(y))
        return .ok
    }

    /// Double-click at the given screen coordinates.
    @discardableResult
    func doubleClickAt(x: Double, y: Double) -> ActionResult {
        preflightWarn("doubleClickAt(\(Int(x)),\(Int(y)))")
        let point = CGPoint(x: x, y: y)

        guard let click1Down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let click1Up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left),
              let click2Down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let click2Up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ doubleClickAt — CGEvent creation returned nil")
            return .failed("CGEvent creation failed for double-click")
        }

        click2Down.setIntegerValueField(.mouseEventClickState, value: 2)
        click2Up.setIntegerValueField(.mouseEventClickState, value: 2)

        click1Down.post(tap: .cghidEventTap)
        click1Up.post(tap: .cghidEventTap)
        usleep(50_000)
        click2Down.post(tap: .cghidEventTap)
        click2Up.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ doubleClickAt(%d,%d) posted", Int(x), Int(y))
        return .ok
    }

    /// Type a string of text using keyboard events.
    @discardableResult
    func typeText(_ text: String) -> ActionResult {
        preflightWarn("typeText(\(text.prefix(30)))")

        // Test that CGEvent creation works with a single probe event
        guard CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) != nil else {
            NSLog("CyclopOne [AccessibilityService]: ❌ typeText — CGEvent probe returned nil")
            return .failed("CGEvent creation failed for typing — accessibility permission may not be fully active.")
        }

        var charsTyped = 0
        for character in text {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)

            guard let keyDown = keyDown, let keyUp = keyUp else {
                NSLog("CyclopOne [AccessibilityService]: ❌ typeText — CGEvent nil at char %d", charsTyped)
                return .failed("CGEvent creation failed at character \(charsTyped)")
            }

            var unicodeChar = Array(String(character).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            keyUp.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(10_000) // 10ms between keystrokes
            charsTyped += 1
        }
        NSLog("CyclopOne [AccessibilityService]: ✓ typeText — %d chars posted", charsTyped)
        return .ok
    }

    /// Press a keyboard shortcut (e.g., Command+S).
    @discardableResult
    func pressShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) -> ActionResult {
        preflightWarn("pressShortcut(key=\(keyCode))")

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ pressShortcut — CGEvent creation returned nil")
            return .failed("CGEvent creation failed for key press")
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ pressShortcut(key=%d) posted", keyCode)
        return .ok
    }

    /// Right-click at the given screen coordinates.
    @discardableResult
    func rightClickAt(x: Double, y: Double) -> ActionResult {
        preflightWarn("rightClickAt(\(Int(x)),\(Int(y)))")
        let point = CGPoint(x: x, y: y)

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ rightClickAt — CGEvent creation returned nil")
            return .failed("CGEvent creation failed for right-click")
        }

        mouseDown.post(tap: .cghidEventTap)
        usleep(50_000)
        mouseUp.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ rightClickAt(%d,%d) posted", Int(x), Int(y))
        return .ok
    }

    /// Drag from one point to another.
    @discardableResult
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double) -> ActionResult {
        preflightWarn("drag")
        let from = CGPoint(x: fromX, y: fromY)
        let to = CGPoint(x: toX, y: toY)

        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ drag — CGEvent creation returned nil")
            return .failed("CGEvent creation failed for drag")
        }

        move.post(tap: .cghidEventTap)
        usleep(50_000)
        down.post(tap: .cghidEventTap)
        usleep(50_000)

        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let midX = fromX + (toX - fromX) * t
            let midY = fromY + (toY - fromY) * t
            let mid = CGPoint(x: midX, y: midY)
            if let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: mid, mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            usleep(20_000)
        }

        up.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ drag posted")
        return .ok
    }

    /// Scroll at the given coordinates.
    @discardableResult
    func scroll(x: Double, y: Double, deltaY: Int) -> ActionResult {
        preflightWarn("scroll")
        let point = CGPoint(x: x, y: y)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ scroll — CGEvent move returned nil")
            return .failed("CGEvent creation failed for scroll move")
        }
        move.post(tap: .cghidEventTap)
        usleep(30_000)

        guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ scroll — CGEvent scroll returned nil")
            return .failed("CGEvent creation failed for scroll")
        }
        scroll.post(tap: .cghidEventTap)
        NSLog("CyclopOne [AccessibilityService]: ✓ scroll posted")
        return .ok
    }

    /// Move mouse to coordinates without clicking.
    @discardableResult
    func moveMouse(x: Double, y: Double) -> ActionResult {
        // moveMouse doesn't need full preflight — it's a positioning helper
        let point = CGPoint(x: x, y: y)
        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            NSLog("CyclopOne [AccessibilityService]: ❌ moveMouse — CGEvent returned nil")
            return .failed("CGEvent creation failed for mouse move")
        }
        moveEvent.post(tap: .cghidEventTap)
        return .ok
    }

    // MARK: - Password Field Detection (Sprint 17)

    /// Represents a detected password field's screen frame for redaction.
    struct PasswordFieldFrame {
        let frame: CGRect  // In CG-space (top-left origin)
    }

    /// Detect all password fields (AXSecureTextField) in the focused application's UI tree.
    /// Returns their screen-space frames for use in screenshot redaction.
    func detectPasswordFields() -> [PasswordFieldFrame] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var results: [PasswordFieldFrame] = []
        findSecureTextFields(appElement, depth: 0, maxDepth: 8, results: &results)
        return results
    }

    /// Detect password fields across all running applications (for full-screen capture redaction).
    func detectAllPasswordFields() -> [PasswordFieldFrame] {
        var allFrames: [PasswordFieldFrame] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            findSecureTextFields(appElement, depth: 0, maxDepth: 8, results: &allFrames)
        }

        return allFrames
    }

    /// Recursively search for AXSecureTextField elements and collect their frames.
    private func findSecureTextFields(_ element: AXUIElement, depth: Int, maxDepth: Int, results: inout [PasswordFieldFrame]) {
        guard depth <= maxDepth else { return }

        let role = getStringAttribute(element, kAXRoleAttribute as CFString)

        // AXSecureTextField is the role for password input fields
        if role == "AXSecureTextField" {
            if let frame = getElementFrame(element) {
                results.append(PasswordFieldFrame(frame: frame))
            }
        }

        // Also check subrole for secure text fields that may use a different role
        let subrole = getStringAttribute(element, kAXSubroleAttribute as CFString)
        if subrole == "AXSecureTextField" && role != "AXSecureTextField" {
            if let frame = getElementFrame(element) {
                results.append(PasswordFieldFrame(frame: frame))
            }
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let childArray = childrenRef as? [AXUIElement] {
            for child in childArray.prefix(30) {
                findSecureTextFields(child, depth: depth + 1, maxDepth: maxDepth, results: &results)
            }
        }
    }

    /// Get the screen frame of an AXUIElement in CG-space coordinates.
    private func getElementFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        // AXPosition returns screen coordinates in CG-space (top-left origin)
        return CGRect(origin: position, size: size)
    }

    // MARK: - Private Helpers

    private func readElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> UITreeNode? {
        guard depth <= maxDepth else { return nil }

        let role = getStringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown"
        let title = getStringAttribute(element, kAXTitleAttribute as CFString)
        let value = getStringAttribute(element, kAXValueAttribute as CFString)
        let description = getStringAttribute(element, kAXDescriptionAttribute as CFString)
        let label = getStringAttribute(element, kAXLabelValueAttribute as CFString)

        var position: CGPoint?
        var size: CGSize?

        var posValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success {
            var point = CGPoint.zero
            if AXValueGetValue(posValue as! AXValue, .cgPoint, &point) {
                position = point
            }
        }

        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success {
            var s = CGSize.zero
            if AXValueGetValue(sizeValue as! AXValue, .cgSize, &s) {
                size = s
            }
        }

        // Read children
        var children: [UITreeNode] = []
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let childArray = childrenRef as? [AXUIElement] {
            // Limit children to avoid huge trees
            for child in childArray.prefix(20) {
                if let childNode = readElement(child, depth: depth + 1, maxDepth: maxDepth) {
                    children.append(childNode)
                }
            }
        }

        return UITreeNode(
            role: role,
            title: title,
            value: value?.prefix(100).description, // Truncate long values
            description: description,
            label: label,
            position: position,
            size: size,
            children: children
        )
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String, !stringValue.isEmpty else {
            return nil
        }
        return stringValue
    }

    private func formatNode(_ node: UITreeNode, indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        var line = "\(prefix)[\(node.role)]"

        if let title = node.title { line += " title=\"\(title)\"" }
        if let desc = node.description { line += " desc=\"\(desc)\"" }
        if let label = node.label { line += " label=\"\(label)\"" }
        if let value = node.value, !value.isEmpty { line += " value=\"\(value)\"" }
        if let pos = node.position, let size = node.size {
            line += " pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height)))"
        }
        line += "\n"

        for child in node.children {
            line += formatNode(child, indent: indent + 1)
        }
        return line
    }
}

// MARK: - UI Tree Model

struct UITreeNode: Sendable {
    let role: String
    let title: String?
    let value: String?
    let description: String?
    let label: String?
    let position: CGPoint?
    let size: CGSize?
    let children: [UITreeNode]
}
