import Foundation

/// Handles shell command and AppleScript execution tools.
struct ShellToolHandler {

    func execute(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> ToolResult {
        let config = await context.agentConfig
        let executor = context.actionExecutor

        switch name {
        case "run_applescript":
            return await handleAppleScript(input: input, context: context, executor: executor)
        case "run_shell_command":
            return await handleShellCommand(input: input, config: config, executor: executor, onMessage: onMessage)
        default:
            return ToolResult(result: "Unknown shell tool: \(name)", isError: true)
        }
    }

    // MARK: - AppleScript

    private func handleAppleScript(
        input: [String: Any],
        context: ToolExecutionContext,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let script = input["script"] as? String else {
            return ToolResult(result: "Error: missing 'script'", isError: true)
        }
        do {
            let result = try await executor.runAppleScript(script)
            if script.lowercased().contains("activate") {
                await context.updateTargetPID()
            }
            return ToolResult(result: "AppleScript: \(result)", isError: false)
        } catch {
            return ToolResult(result: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Shell Command

    private func handleShellCommand(
        input: [String: Any],
        config: AgentConfig,
        executor: ActionExecutor,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> ToolResult {
        guard let command = (input["command"] as? String) ?? (input["cmd"] as? String) else {
            return ToolResult(result: "Error: missing 'command'", isError: true)
        }
        do {
            let result = try await executor.runShellCommand(command, timeout: config.shellTimeout)
            onMessage(ChatMessage(role: .toolResult, content: "$ \(command)\n\(result.summary)"))
            return ToolResult(result: result.summary, isError: !result.isSuccess)
        } catch {
            return ToolResult(result: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}
