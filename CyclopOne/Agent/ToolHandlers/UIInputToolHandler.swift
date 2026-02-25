import Foundation
import AppKit

/// Handles CGEvent-based UI input tools: click, right_click, type_text, press_key, move_mouse, drag, scroll.
struct UIInputToolHandler {

    func execute(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext
    ) async -> ToolResult {
        let executor = context.actionExecutor
        let accessibility = context.accessibilityService

        switch name {
        case "click", "right_click":
            return await handleClick(name: name, input: input, context: context, accessibility: accessibility, executor: executor)
        case "type_text":
            return await handleTypeText(input: input, context: context, accessibility: accessibility, executor: executor)
        case "press_key":
            return await handlePressKey(input: input, context: context, accessibility: accessibility, executor: executor)
        case "move_mouse":
            return await handleMoveMouse(input: input, context: context, accessibility: accessibility)
        case "drag":
            return await handleDrag(input: input, context: context, accessibility: accessibility)
        case "scroll":
            return await handleScroll(input: input, context: context, accessibility: accessibility)
        default:
            return ToolResult(result: "Unknown UI input tool: \(name)", isError: true)
        }
    }

    // MARK: - Click

    private func handleClick(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let rawX = input["x"] as? Double, let rawY = input["y"] as? Double else {
            return ToolResult(result: "Error: missing x/y", isError: true)
        }
        let isDouble = input["double_click"] as? Bool ?? false
        let isRight = (name == "right_click")
        let (sx, sy) = await context.mapToScreen(x: rawX, y: rawY)
        let timing = await executor.timing

        await context.activateTargetApp()
        await context.letClicksThrough()

        await accessibility.moveMouse(x: sx, y: sy)
        try? await Task.sleep(nanoseconds: timing.clickDelayBefore)

        let clickResult: AccessibilityService.ActionResult
        if isRight {
            clickResult = await accessibility.rightClickAt(x: sx, y: sy)
        } else if isDouble {
            clickResult = await accessibility.doubleClickAt(x: sx, y: sy)
        } else {
            clickResult = await accessibility.clickAt(x: sx, y: sy)
        }

        try? await Task.sleep(nanoseconds: timing.clickDelayAfter)
        await context.stopClicksThrough()
        await context.updateTargetPID()

        if !clickResult.success {
            return ToolResult(result: "Error: \(clickResult.error ?? "click failed")", isError: true)
        }

        let clickType = isRight ? "Right-clicked" : (isDouble ? "Double-clicked" : "Clicked")
        return ToolResult(result: "\(clickType) at screenshot(\(Int(rawX)),\(Int(rawY))) -> screen(\(Int(sx)),\(Int(sy)))", isError: false)
    }

    // MARK: - Type Text

    private func handleTypeText(
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let text = input["text"] as? String else {
            return ToolResult(result: "Error: missing 'text'", isError: true)
        }
        let typeTiming = await executor.timing

        await context.activateTargetApp()
        let typeResult = await accessibility.typeText(text)

        if !typeResult.success {
            return ToolResult(result: "Error: \(typeResult.error ?? "typing failed")", isError: true)
        }

        let typingTime = UInt64(text.count) * typeTiming.typingDelayPerChar
        try? await Task.sleep(nanoseconds: max(typingTime, typeTiming.typingMinSettle))
        return ToolResult(result: "Typed: \(text.prefix(100))\(text.count > 100 ? "..." : "")", isError: false)
    }

    // MARK: - Press Key

    private func handlePressKey(
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let keyName = input["key"] as? String else {
            return ToolResult(result: "Error: missing 'key'", isError: true)
        }
        guard let keyCode = ActionExecutor.keyCodes[keyName.lowercased()] else {
            return ToolResult(result: "Error: unknown key '\(keyName)'", isError: true)
        }
        let cmd = input["command"] as? Bool ?? false
        let shift = input["shift"] as? Bool ?? false
        let opt = input["option"] as? Bool ?? false
        let ctrl = input["control"] as? Bool ?? false

        await context.activateTargetApp()

        var flags = CGEventFlags()
        if cmd { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if opt { flags.insert(.maskAlternate) }
        if ctrl { flags.insert(.maskControl) }
        let keyResult = await accessibility.pressShortcut(keyCode: keyCode, modifiers: flags)

        if !keyResult.success {
            return ToolResult(result: "Error: \(keyResult.error ?? "key press failed")", isError: true)
        }

        let keyTiming = await executor.timing
        try? await Task.sleep(nanoseconds: keyTiming.keyPressDelay)

        var desc = keyName
        if cmd { desc = "Cmd+" + desc }
        if shift { desc = "Shift+" + desc }
        if opt { desc = "Opt+" + desc }
        if ctrl { desc = "Ctrl+" + desc }
        return ToolResult(result: "Pressed: \(desc)", isError: false)
    }

    // MARK: - Move Mouse

    private func handleMoveMouse(
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService
    ) async -> ToolResult {
        guard let rawX = input["x"] as? Double, let rawY = input["y"] as? Double else {
            return ToolResult(result: "Error: missing x/y", isError: true)
        }
        let (sx, sy) = await context.mapToScreen(x: rawX, y: rawY)
        await context.activateTargetApp()
        await context.letClicksThrough()
        await accessibility.moveMouse(x: sx, y: sy)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await context.stopClicksThrough()
        return ToolResult(result: "Moved to screen(\(Int(sx)),\(Int(sy)))", isError: false)
    }

    // MARK: - Drag

    private func handleDrag(
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService
    ) async -> ToolResult {
        guard let fX = input["from_x"] as? Double, let fY = input["from_y"] as? Double,
              let tX = input["to_x"] as? Double, let tY = input["to_y"] as? Double else {
            return ToolResult(result: "Error: missing coordinates", isError: true)
        }
        let (sx1, sy1) = await context.mapToScreen(x: fX, y: fY)
        let (sx2, sy2) = await context.mapToScreen(x: tX, y: tY)

        await context.activateTargetApp()
        await context.letClicksThrough()
        await accessibility.drag(fromX: sx1, fromY: sy1, toX: sx2, toY: sy2)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await context.stopClicksThrough()
        return ToolResult(result: "Dragged (\(Int(sx1)),\(Int(sy1))) -> (\(Int(sx2)),\(Int(sy2)))", isError: false)
    }

    // MARK: - Scroll

    private func handleScroll(
        input: [String: Any],
        context: ToolExecutionContext,
        accessibility: AccessibilityService
    ) async -> ToolResult {
        guard let rawX = input["x"] as? Double, let rawY = input["y"] as? Double else {
            return ToolResult(result: "Error: missing x/y", isError: true)
        }
        let deltaY = input["delta_y"] as? Int ?? -3
        let (sx, sy) = await context.mapToScreen(x: rawX, y: rawY)

        await context.activateTargetApp()
        await context.letClicksThrough()
        await accessibility.scroll(x: sx, y: sy, deltaY: deltaY)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await context.stopClicksThrough()
        return ToolResult(result: "Scrolled \(deltaY > 0 ? "up" : "down") \(abs(deltaY)) at (\(Int(sx)),\(Int(sy)))", isError: false)
    }
}
