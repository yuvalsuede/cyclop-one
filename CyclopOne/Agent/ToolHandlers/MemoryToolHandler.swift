import Foundation

/// Handles vault, task, and memory tools (vault_*, task_*, remember, recall, openclaw_*).
struct MemoryToolHandler {

    func execute(
        name: String,
        input: [String: Any]
    ) async -> ToolResult {
        switch name {
        case "vault_read":
            return await handleVaultRead(input: input)
        case "vault_write":
            return await handleVaultWrite(input: input)
        case "vault_append":
            return await handleVaultAppend(input: input)
        case "vault_search":
            return await handleVaultSearch(input: input)
        case "vault_list":
            return await handleVaultList(input: input)
        case "task_create":
            return await handleTaskCreate(input: input)
        case "task_update":
            return await handleTaskUpdate(input: input)
        case "task_list":
            return await handleTaskList(input: input)
        case "remember":
            return await handleRemember(input: input)
        case "recall":
            return await handleRecall(input: input)
        case "openclaw_send":
            return await handleOpenClawSend(input: input)
        case "openclaw_check":
            return await handleOpenClawCheck(input: input)
        default:
            return ToolResult(result: "Unknown memory tool: \(name)", isError: true)
        }
    }

    // MARK: - Vault

    private func handleVaultRead(input: [String: Any]) async -> ToolResult {
        guard let path = input["path"] as? String else {
            return ToolResult(result: "Error: missing 'path'", isError: true)
        }
        let content = await MemoryService.shared.readNote(at: path)
        return ToolResult(result: content ?? "Note not found: \(path)", isError: content == nil)
    }

    private func handleVaultWrite(input: [String: Any]) async -> ToolResult {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String else {
            return ToolResult(result: "Error: missing 'path' or 'content'", isError: true)
        }
        do {
            try await MemoryService.shared.writeNote(at: path, content: content)
            return ToolResult(result: "Wrote note: \(path)", isError: false)
        } catch {
            return ToolResult(result: "Error writing note: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleVaultAppend(input: [String: Any]) async -> ToolResult {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String else {
            return ToolResult(result: "Error: missing 'path' or 'content'", isError: true)
        }
        do {
            try await MemoryService.shared.appendToNote(at: path, text: content)
            return ToolResult(result: "Appended to note: \(path)", isError: false)
        } catch {
            return ToolResult(result: "Error appending to note: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleVaultSearch(input: [String: Any]) async -> ToolResult {
        guard let query = input["query"] as? String else {
            return ToolResult(result: "Error: missing 'query'", isError: true)
        }
        let folder = input["directory"] as? String
        let limit = input["limit"] as? Int ?? 10
        let results = await MemoryService.shared.searchNotes(query: query, folder: folder, limit: limit)
        if results.isEmpty {
            return ToolResult(result: "No notes found matching: \(query)", isError: false)
        }
        let formatted = results.map { "**\($0.path)**: \($0.snippet)" }.joined(separator: "\n\n")
        return ToolResult(result: formatted, isError: false)
    }

    private func handleVaultList(input: [String: Any]) async -> ToolResult {
        let directory = input["directory"] as? String ?? ""
        let items = await MemoryService.shared.listNotes(in: directory)
        if items.isEmpty {
            return ToolResult(result: "Directory is empty or does not exist: \(directory)", isError: false)
        }
        return ToolResult(result: items.joined(separator: "\n"), isError: false)
    }

    // MARK: - Tasks

    private func handleTaskCreate(input: [String: Any]) async -> ToolResult {
        guard let title = input["title"] as? String else {
            return ToolResult(result: "Error: missing 'title'", isError: true)
        }
        let details = input["details"] as? String ?? ""
        let priority = input["priority"] as? String ?? "medium"
        let project = input["project"] as? String
        do {
            let path = try await MemoryService.shared.createTask(
                title: title, description: details,
                priority: priority, project: project
            )
            return ToolResult(result: "Created task: \(title) at \(path)", isError: false)
        } catch {
            return ToolResult(result: "Error creating task: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleTaskUpdate(input: [String: Any]) async -> ToolResult {
        guard let title = input["title"] as? String,
              let status = input["status"] as? String else {
            return ToolResult(result: "Error: missing 'title' or 'status'", isError: true)
        }
        let notes = input["notes"] as? String
        await MemoryService.shared.updateTaskByTitle(title: title, status: status, notes: notes)
        return ToolResult(result: "Updated task '\(title)' to status: \(status)", isError: false)
    }

    private func handleTaskList(input: [String: Any]) async -> ToolResult {
        let status = input["status"] as? String
        let project = input["project"] as? String
        let list = await MemoryService.shared.listTasks(status: status, project: project)
        return ToolResult(result: list, isError: false)
    }

    // MARK: - Memory

    private func handleRemember(input: [String: Any]) async -> ToolResult {
        guard let fact = input["fact"] as? String else {
            return ToolResult(result: "Error: missing 'fact'", isError: true)
        }
        let category = input["category"] as? String ?? "fact"
        await MemoryService.shared.remember(fact: fact, category: category)
        return ToolResult(result: "Remembered [\(category)]: \(fact)", isError: false)
    }

    private func handleRecall(input: [String: Any]) async -> ToolResult {
        guard let topic = input["topic"] as? String else {
            return ToolResult(result: "Error: missing 'topic'", isError: true)
        }
        let memories = await MemoryService.shared.recall(topic: topic)
        return ToolResult(result: memories, isError: false)
    }

    // MARK: - OpenClaw

    private func handleOpenClawSend(input: [String: Any]) async -> ToolResult {
        guard let message = input["message"] as? String else {
            return ToolResult(result: "Error: missing 'message'", isError: true)
        }
        let channel = input["channel"] as? String ?? "telegram"
        let target = input["target"] as? String ?? ""
        do {
            let result = try await OpenClawBridge.shared.sendMessage(
                channel: channel, target: target, message: message
            )
            return ToolResult(result: "Message sent via \(channel): \(result)", isError: false)
        } catch {
            return ToolResult(result: "Error sending message: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleOpenClawCheck(input: [String: Any]) async -> ToolResult {
        let channel = input["channel"] as? String ?? "telegram"
        let target = input["target"] as? String ?? ""
        let limit = input["limit"] as? Int ?? 10
        do {
            let messages = try await OpenClawBridge.shared.readMessages(
                channel: channel, target: target, limit: limit
            )
            if messages.isEmpty {
                return ToolResult(result: "No new messages.", isError: false)
            }
            let formatted = messages.map { msg in
                let sender = msg.sender ?? "unknown"
                let time = msg.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                return "[\(time)] \(sender): \(msg.text)"
            }.joined(separator: "\n")
            return ToolResult(result: formatted, isError: false)
        } catch {
            return ToolResult(result: "Error reading messages: \(error.localizedDescription)", isError: true)
        }
    }
}
