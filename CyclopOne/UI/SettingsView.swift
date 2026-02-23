import SwiftUI

/// Sprint 20: Reorganized settings panel with categorized sections.
///
/// Sections: General, Permissions, Advanced
struct SettingsView: View {
    @EnvironmentObject var coordinator: AgentCoordinator

    // General
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false
    @AppStorage("selectedModel") private var selectedModel: String = "claude-haiku-4-5-20251001"
    @State private var savedMessage: String?

    // Telegram
    @State private var telegramToken: String = ""
    @State private var showTelegramToken: Bool = false
    @State private var telegramSavedMessage: String?
    @State private var telegramConnected: Bool = false
    @AppStorage("telegramChatID") private var telegramChatID: Int = 0

    // Agent behavior
    @AppStorage("maxIterations") private var maxIterations: Double = 15
    @AppStorage("confirmDestructive") private var confirmDestructive: Bool = true

    // Memory Vault
    @State private var legacyVaultExists: Bool = false

    // Disk usage (Sprint 16)
    @State private var diskUsage: RunJournal.DiskUsageInfo?
    @State private var isCleaningUp: Bool = false
    @State private var cleanupMessage: String?

    private let models = [
        ("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5 ($3/$15)"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 ($3/$15)"),
        ("claude-opus-4-6", "Claude Opus 4.6 ($5/$25)"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 ($1/$5)"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            permissionsTab
                .tabItem {
                    Label("Permissions", systemImage: "shield.checkered")
                }

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 520, height: 480)
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Claude API Key") {
                HStack {
                    if showAPIKey {
                        TextField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { showAPIKey.toggle() }) {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save Key") {
                        if KeychainService.shared.setAPIKey(apiKey) {
                            savedMessage = "API key saved securely."
                        } else {
                            savedMessage = "Failed to save API key."
                        }
                    }
                    .disabled(apiKey.isEmpty)

                    if let msg = savedMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.contains("Failed") ? .red : .green)
                    }
                }

                Text("Your API key is stored in the macOS Keychain and never leaves your machine except to authenticate with the Anthropic API.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Model") {
                Picker("Model", selection: $selectedModel) {
                    ForEach(models, id: \.0) { model in
                        Text(model.1).tag(model.0)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("Sonnet is faster and cheaper. Opus is more capable for complex multi-step tasks.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Hotkey") {
                HStack {
                    Text("Toggle Cyclop One")
                    Spacer()
                    Text("\u{2318}\u{21E7}A")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(6)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Press Command+Shift+A anywhere to show/hide the Cyclop One panel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Telegram") {
                HStack {
                    if showTelegramToken {
                        TextField("Bot token from @BotFather", text: $telegramToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("Bot token from @BotFather", text: $telegramToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { showTelegramToken.toggle() }) {
                        Image(systemName: showTelegramToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Save Token") {
                        if KeychainService.shared.setTelegramToken(telegramToken) {
                            telegramSavedMessage = "Token saved. Connecting..."
                            let gw = coordinator.gateway
                            let tok = telegramToken
                            Task.detached {
                                await TelegramService.shared.start(gateway: gw, token: tok)
                            }
                            // Check status after a delay
                            Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                checkTelegramStatus()
                            }
                        } else {
                            telegramSavedMessage = "Failed to save token."
                        }
                    }
                    .disabled(telegramToken.isEmpty)

                    if telegramConnected {
                        Button("Disconnect") {
                            Task {
                                await TelegramService.shared.stop()
                                KeychainService.shared.deleteTelegramToken()
                                telegramToken = ""
                                telegramConnected = false
                                telegramSavedMessage = "Disconnected."
                            }
                        }
                        .foregroundColor(.red)
                    }

                    if let msg = telegramSavedMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.contains("Failed") ? .red : .green)
                    }
                }

                HStack {
                    Image(systemName: telegramConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(telegramConnected ? .green : .secondary)
                    Text(telegramConnected ? "Connected" : "Not connected")
                        .font(.caption)
                    if telegramChatID != 0 {
                        Spacer()
                        Text("Chat ID: \(telegramChatID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Create a bot via @BotFather on Telegram, paste the token here. Then send /start to your bot to connect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Memory Vault") {
                HStack {
                    Text("Vault location")
                    Spacer()
                    Text("~/Documents/Obsidian Vault/Cyclop One/")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Open in Finder") {
                        let path = MemoryService.shared.vaultRootPath
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }

                    Button("Open in Obsidian") {
                        let obsidianURL = URL(string: "obsidian://open?vault=Cyclop%20One")!
                        if NSWorkspace.shared.urlForApplication(toOpen: obsidianURL) != nil {
                            NSWorkspace.shared.open(obsidianURL)
                        } else {
                            // Obsidian not installed — fall back to Finder
                            let path = MemoryService.shared.vaultRootPath
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                    }
                }

                if legacyVaultExists {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Legacy vault found at ~/.cyclopone/memory/. It has been migrated and can be safely deleted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Your agent's memory is stored as plain Markdown files. Open the vault in Obsidian to browse, search, and edit notes. Changes you make are picked up automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        Form {
            Section("System Permissions") {
                PermissionRow(
                    name: "Screen Recording",
                    description: "Required to capture screenshots of your desktop",
                    isGranted: checkScreenRecording()
                )
                PermissionRow(
                    name: "Accessibility",
                    description: "Required to read UI elements and perform clicks/keystrokes",
                    isGranted: AccessibilityService.shared.isAccessibilityEnabled()
                )

                Button("Open System Settings > Privacy") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .font(.caption)
            }

            Section("Privacy") {
                Text("Cyclop One sends screenshots of your screen to the Anthropic API when executing tasks. No data is stored persistently beyond run journals. Conversation history is cleared when you quit the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Clear Conversation History") {
                    coordinator.clearConversation()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            Section("Agent Behavior") {
                HStack {
                    Text("Max iterations per task")
                    Spacer()
                    Text("\(Int(maxIterations))")
                        .foregroundColor(.secondary)
                }
                Slider(value: $maxIterations, in: 5...50, step: 5)

                Toggle("Confirm destructive actions", isOn: $confirmDestructive)

                Text("When enabled, the agent asks for approval before running commands that could delete files, use sudo, or make system changes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Run Data & Storage") {
                if let usage = diskUsage {
                    HStack {
                        Text("Total disk usage")
                        Spacer()
                        Text(usage.formattedTotal)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Runs stored")
                        Spacer()
                        Text("\(usage.runCount)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Screenshots")
                        Spacer()
                        Text("\(usage.screenshotCount) (\(usage.formattedScreenshots))")
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Text("Loading disk usage...")
                            .foregroundColor(.secondary)
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack {
                    Button("Clean Up Old Runs") {
                        cleanUpOldRuns()
                    }
                    .disabled(isCleaningUp)

                    if isCleaningUp {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let msg = cleanupMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                Text("Retention: completed runs 30 days, failed 7 days, abandoned 3 days. Intermediate screenshots are pruned for completed runs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshDiskUsage()
        }
    }

    // MARK: - Helpers

    private func loadSettings() {
        apiKey = KeychainService.shared.getAPIKey() ?? ""
        telegramToken = KeychainService.shared.getTelegramToken() ?? ""
        checkTelegramStatus()
        legacyVaultExists = FileManager.default.fileExists(atPath: MemoryService.legacyVaultRoot.path)
    }

    private func checkTelegramStatus() {
        Task {
            let started = await TelegramService.shared.isStarted
            await MainActor.run {
                telegramConnected = started
            }
        }
    }

    private func checkScreenRecording() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    private func refreshDiskUsage() {
        Task.detached(priority: .utility) {
            let usage = RunJournal.diskUsage()
            await MainActor.run {
                self.diskUsage = usage
            }
        }
    }

    private func cleanUpOldRuns() {
        isCleaningUp = true
        cleanupMessage = nil

        Task.detached(priority: .utility) {
            let deleted = RunJournal.cleanupOldRuns()
            let usage = RunJournal.diskUsage()

            await MainActor.run {
                self.isCleaningUp = false
                self.diskUsage = usage
                if deleted > 0 {
                    self.cleanupMessage = "Deleted \(deleted) old run\(deleted == 1 ? "" : "s")."
                } else {
                    self.cleanupMessage = "Nothing to clean up."
                }
            }
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let description: String
    let isGranted: Bool

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isGranted ? .green : .red)
            VStack(alignment: .leading) {
                Text(name).font(.body)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(isGranted ? "Granted" : "Not Granted")
                .font(.caption)
                .foregroundColor(isGranted ? .green : .red)
        }
    }
}
