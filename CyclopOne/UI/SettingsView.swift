import SwiftUI

/// Sprint 20: Reorganized settings panel with categorized sections.
///
/// Sections: General, Permissions, Advanced
struct SettingsView: View {
    @EnvironmentObject var coordinator: AgentCoordinator

    // General
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false
    @AppStorage("selectedModel") private var selectedModel: String = "claude-sonnet-4-6"
    @State private var savedMessage: String?

    // Agent behavior
    @AppStorage("maxIterations") private var maxIterations: Double = 20
    @AppStorage("confirmDestructive") private var confirmDestructive: Bool = true

    // Disk usage (Sprint 16)
    @State private var diskUsage: RunJournal.DiskUsageInfo?
    @State private var isCleaningUp: Bool = false
    @State private var cleanupMessage: String?

    private let models = [
        ("claude-sonnet-4-6", "Claude Sonnet 4.6 (Fast)"),
        ("claude-opus-4-6", "Claude Opus 4.6 (Capable)"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (Fastest)"),
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
