import SwiftUI

/// Popover shown when the user clicks the floating dot.
/// Shows status, command input, stop button, command history, and error history.
struct DotPopoverView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @State private var commandText = ""
    @FocusState private var isCommandFocused: Bool
    @State private var showSkillsMarketplace = false
    let onDismiss: () -> Void

    /// Past user commands (most recent first, max 10)
    private var commandHistory: [ChatMessage] {
        coordinator.messages
            .filter { $0.role == .user }
            .suffix(10)
            .reversed()
    }

    /// Recent error/warning messages from the agent (most recent first, max 10).
    /// Filters system messages that contain error or warning indicators.
    private var errorHistory: [ChatMessage] {
        coordinator.messages
            .filter { msg in
                guard msg.role == .system else { return false }
                let lower = msg.content.lowercased()
                return lower.contains("error") ||
                       lower.contains("warning") ||
                       lower.contains("failed") ||
                       lower.contains("cancelled") ||
                       lower.contains("timed out") ||
                       lower.contains("abort") ||
                       lower.contains("stuck")
            }
            .suffix(10)
            .reversed()
    }

    /// Recent meaningful chat messages for the live feed (last 8, excluding loading/empty).
    private var recentChatMessages: [ChatMessage] {
        coordinator.messages
            .filter { msg in
                // Skip loading placeholders and empty content
                guard !msg.isLoading, !msg.content.isEmpty else { return false }
                // Show assistant, system, and toolResult messages (skip user — they're in history)
                return msg.role == .assistant || msg.role == .system || msg.role == .toolResult
            }
            .suffix(8)
            .map { $0 }  // Convert ArraySlice to Array
    }

    /// Color indicator for a message role.
    private func roleColor(_ role: ChatMessage.Role) -> Color {
        switch role {
        case .assistant: return .blue
        case .system: return .orange
        case .toolResult: return .purple
        case .user: return .green
        }
    }

    /// Whether the agent state is in error
    private var isErrorState: Bool {
        if case .error = coordinator.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(coordinator.state.displayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isErrorState ? .red : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if coordinator.state.isActive {
                    Button(action: {
                        coordinator.cancel()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 12))
                            Text("Stop")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .help("Stop current task (Esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }

            // Confirmation UI — show approve/deny when awaiting confirmation
            if case .awaitingConfirmation(let action) = coordinator.state {
                VStack(alignment: .leading, spacing: 6) {
                    Text(action)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Allow") {
                            coordinator.approveConfirmation()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)

                        Button("Deny") {
                            coordinator.denyConfirmation()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            }

            // Step progress indicator — show when a multi-step plan is executing
            if coordinator.state.isActive, coordinator.totalSteps > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.stepProgressText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.1))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(
                                    width: geo.size.width * CGFloat(coordinator.currentStepNumber) / CGFloat(max(coordinator.totalSteps, 1)),
                                    height: 4
                                )
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.vertical, 2)
            }

            // Chat message feed — show recent messages (always visible when there are messages)
            if !recentChatMessages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(recentChatMessages) { msg in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(roleColor(msg.role))
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 4)
                                    Text(msg.content)
                                        .font(.system(size: 10))
                                        .foregroundColor(msg.role == .system ? .secondary : .primary)
                                        .lineLimit(3)
                                        .truncationMode(.tail)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(msg.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 120)
                    .onChange(of: recentChatMessages.count) { _, _ in
                        if let last = recentChatMessages.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.3)

            // Command input
            HStack(spacing: 4) {
                TextField("Tell me what to do...", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isCommandFocused)
                    .onSubmit { submitCommand() }
                    .disabled(coordinator.state.isActive)

                Button(action: submitCommand) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(commandText.isEmpty || coordinator.state.isActive ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(commandText.isEmpty || coordinator.state.isActive)
            }
            .padding(6)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Error history section — always visible when there are errors
            if !errorHistory.isEmpty {
                Divider().opacity(0.3)

                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.7))
                    Text("Errors")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                    Spacer()
                    Text("\(errorHistory.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.red.opacity(0.6))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errorHistory) { msg in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(Color.red.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(msg.content)
                                        .font(.system(size: 10))
                                        .foregroundColor(.red.opacity(0.9))
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                    Text(msg.timestamp, style: .relative)
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 80)
            }

            // Command history section
            if !commandHistory.isEmpty {
                Divider().opacity(0.3)

                HStack {
                    Text("History")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(commandHistory) { msg in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text(msg.content)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !coordinator.state.isActive {
                                    commandText = msg.content
                                }
                            }
                            .help("Click to reuse this command")
                        }
                    }
                }
                .frame(maxHeight: 80)
            }

            // Footer: Clear button + token count
            Divider().opacity(0.3)

            HStack {
                Button(action: {
                    coordinator.clearConversation()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("Clear All")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.state.isActive)
                .help("Clear all messages, errors, and history")

                Spacer()

                Button(action: { showSkillsMarketplace = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 9))
                        Text("Skills")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.accentColor.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Browse and manage skills")

                Spacer()

                Text("\(coordinator.totalTokensUsed) tokens")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { isCommandFocused = true }
        .sheet(isPresented: $showSkillsMarketplace) {
            VStack(spacing: 0) {
                HStack {
                    Text("Skills Marketplace")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Done") { showSkillsMarketplace = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                SkillsMarketplaceView()
            }
            .frame(width: 360)
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .idle, .listening, .done: return .green
        case .thinking, .capturing: return .orange
        case .executing: return .blue
        case .awaitingConfirmation: return .yellow
        case .error: return .red
        }
    }

    private func submitCommand() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !coordinator.state.isActive else { return }
        commandText = ""
        Task {
            await coordinator.handleUserMessage(text)
        }
    }
}
