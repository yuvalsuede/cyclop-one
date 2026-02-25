import SwiftUI

/// Expanded first-launch onboarding wizard for Cyclop One.
///
/// Seven-step flow:
/// 0. Welcome — what Cyclop One is and what it does
/// 1. API Key — enter, save, and live-test Claude API key
/// 2. Permissions — check/request Accessibility and Screen Recording
/// 3. Model — choose the AI model (Opus/Sonnet/Haiku)
/// 4. Telegram — optional bot connection
/// 5. Your Vault — Obsidian vault overview + plugins
/// 6. Ready — summary checklist + example commands
struct OnboardingView: View {
    @EnvironmentObject var coordinator: AgentCoordinator

    let onComplete: () -> Void

    @State private var currentStep = 0
    private let totalSteps = 7

    // Step 1: API key
    @State private var apiKey: String = ""
    @State private var apiKeyError: String?
    @State private var isKeyVisible = false
    @State private var isTestingAPI = false
    @State private var apiTestPassed = false
    @State private var apiTestError: String?
    @State private var connectedModelName: String?

    // Step 2: Permissions
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionCheckTimer: Timer?

    // Step 3: Model
    @AppStorage("selectedModel") private var selectedModel = "claude-opus-4-6"

    // Step 4: Telegram
    @State private var telegramToken = ""
    @State private var isTelegramVisible = false
    @State private var isTestingTelegram = false
    @State private var telegramBotName: String?
    @State private var telegramError: String?
    @State private var telegramSkipped = false

    // Step 5: Vault
    @State private var vaultFileCount = 0
    @State private var pluginCount = 0
    @State private var pluginNames: [String] = []
    @AppStorage("vaultPath") private var customVaultPath: String = ""

    // Animation
    @State private var stepAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            // -- Step indicator --
            stepIndicator
                .padding(.top, 28)
                .padding(.bottom, 8)

            // -- Step content --
            ZStack {
                switch currentStep {
                case 0: welcomeStep
                case 1: apiKeyStep
                case 2: permissionsStep
                case 3: modelStep
                case 4: telegramStep
                case 5: vaultStep
                case 6: readyStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.bottom, 16)

            Divider()

            // -- Navigation --
            navigationBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 700)
        .background(
            LinearGradient(
                colors: [Color(.windowBackgroundColor), Color(.windowBackgroundColor).opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            refreshPermissions()
            apiKey = KeychainService.shared.getAPIKey() ?? ""
        }
        .onDisappear {
            permissionCheckTimer?.invalidate()
        }
        .onChange(of: currentStep) { _ in
            stepAppeared = false
            withAnimation(.easeOut(duration: 0.35)) {
                stepAppeared = true
            }
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<totalSteps, id: \.self) { step in
                ZStack {
                    Circle()
                        .fill(step < currentStep ? Color.accentColor : (step == currentStep ? Color.accentColor : Color.secondary.opacity(0.2)))
                        .frame(width: 28, height: 28)

                    if step < currentStep {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                if step < totalSteps - 1 {
                    Rectangle()
                        .fill(step < currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "eye.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 12) {
                Text("Welcome to Cyclop One")
                    .font(.system(size: 28, weight: .bold))

                Text("Your AI Desktop Automation Agent")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "eye",
                    color: .blue,
                    title: "Sees Your Screen",
                    desc: "Captures and understands what is on your display"
                )
                FeatureRow(
                    icon: "cursorarrow.click.2",
                    color: .purple,
                    title: "Takes Actions",
                    desc: "Clicks, types, and navigates applications for you"
                )
                FeatureRow(
                    icon: "brain.head.profile",
                    color: .pink,
                    title: "Thinks with Claude",
                    desc: "Uses Anthropic's Claude to reason about tasks"
                )
                FeatureRow(
                    icon: "lock.shield",
                    color: .green,
                    title: "Privacy First",
                    desc: "Runs locally on your Mac. Your data stays on your machine."
                )
                FeatureRow(
                    icon: "paperplane",
                    color: .cyan,
                    title: "Phone Control",
                    desc: "Send commands via Telegram from anywhere"
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .frame(maxWidth: 420)

            Spacer()
        }
    }

    // MARK: - Step 1: API Key

    private var apiKeyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.orange, .yellow],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 8) {
                Text("Claude API Key")
                    .font(.system(size: 26, weight: .bold))

                Text("Cyclop One uses the Claude API to understand your screen and decide what to do. Enter your API key from Anthropic below.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Group {
                        if isKeyVisible {
                            TextField("sk-ant-api03-...", text: $apiKey)
                        } else {
                            SecureField("sk-ant-api03-...", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(isKeyVisible ? "Hide API key" : "Show API key")
                }

                // Test Connection button + result
                HStack(spacing: 12) {
                    Button {
                        testAPIConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingAPI {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Test Connection")
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingAPI)

                    if apiTestPassed {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected")
                                .foregroundColor(.green)
                            if let model = connectedModelName {
                                Text("(\(model))")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                    }

                    Spacer()
                }

                if let error = apiKeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if let error = apiTestError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: 420)

            Button {
                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Get an API key at console.anthropic.com")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.link)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("Stored securely in your macOS Keychain. Never leaves your machine except to call the Anthropic API.")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: 420)

            Spacer()
        }
    }

    private func testAPIConnection() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isTestingAPI = true
        apiTestError = nil
        apiTestPassed = false
        connectedModelName = nil

        // Save key to keychain first so ClaudeAPIService can find it
        KeychainService.shared.setAPIKey(trimmed)

        Task {
            do {
                let response = try await ClaudeAPIService.shared.sendMessage(
                    messages: [APIMessage.userText("Say hi")],
                    systemPrompt: "Reply with exactly: ok",
                    tools: [],
                    model: AgentConfig.verificationModel,
                    maxTokens: 4
                )
                await MainActor.run {
                    isTestingAPI = false
                    apiTestPassed = true
                    connectedModelName = AgentConfig.verificationModel
                    apiKeyError = nil
                    _ = response // used above
                }
            } catch {
                await MainActor.run {
                    isTestingAPI = false
                    apiTestPassed = false
                    apiTestError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.checkered")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.green, .teal],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 8) {
                Text("System Permissions")
                    .font(.system(size: 26, weight: .bold))

                Text("Cyclop One needs two macOS permissions to see your screen and interact with applications.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 16) {
                permissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Read UI elements, perform clicks and keyboard input",
                    granted: accessibilityGranted,
                    action: {
                        AccessibilityService.shared.requestAccessibility()
                        startPermissionPolling()
                    },
                    openSettings: {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                )

                permissionCard(
                    icon: "record.circle",
                    title: "Screen Recording",
                    description: "Capture screenshots to understand what is on screen",
                    granted: screenRecordingGranted,
                    action: {
                        CGRequestScreenCaptureAccess()
                        startPermissionPolling()
                    },
                    openSettings: {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                )
            }
            .frame(maxWidth: 440)

            if !accessibilityGranted || !screenRecordingGranted {
                Text("After enabling a permission in System Settings, return here. The status will update automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()
        }
        .onAppear {
            refreshPermissions()
            startPermissionPolling()
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(granted ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
            } else {
                VStack(spacing: 4) {
                    Button("Grant") {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Open Settings") {
                        openSettings()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Step 3: Model Selection

    private var modelStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 8) {
                Text("Choose Your Model")
                    .font(.system(size: 26, weight: .bold))

                Text("Select the AI model Cyclop One uses to plan and reason about tasks.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 12) {
                ModelCard(
                    modelID: "claude-opus-4-6",
                    name: "Opus 4.6",
                    badge: "Recommended",
                    description: "Most capable. Best for complex multi-app tasks.",
                    cost: "$$$",
                    icon: "brain.head.profile",
                    color: .purple,
                    isSelected: selectedModel == "claude-opus-4-6"
                ) {
                    selectedModel = "claude-opus-4-6"
                }

                ModelCard(
                    modelID: "claude-sonnet-4-6",
                    name: "Sonnet 4.6",
                    badge: nil,
                    description: "Great balance of speed and capability.",
                    cost: "$$",
                    icon: "hare",
                    color: .blue,
                    isSelected: selectedModel == "claude-sonnet-4-6"
                ) {
                    selectedModel = "claude-sonnet-4-6"
                }

                ModelCard(
                    modelID: "claude-haiku-4-5",
                    name: "Haiku 4.5",
                    badge: nil,
                    description: "Fastest and cheapest. Good for simple tasks.",
                    cost: "$",
                    icon: "bolt",
                    color: .teal,
                    isSelected: selectedModel == "claude-haiku-4-5"
                ) {
                    selectedModel = "claude-haiku-4-5"
                }
            }
            .frame(maxWidth: 440)

            Spacer()
        }
    }

    // MARK: - Step 4: Telegram

    private var telegramStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "paperplane.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 8) {
                Text("Connect Telegram")
                    .font(.system(size: 26, weight: .bold))

                Text("Control Cyclop One from your phone. Optional — you can set this up later.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Setup Instructions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: 8) {
                        Text("1.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.accentColor)
                        Text("Open Telegram → @BotFather → /newbot")
                            .font(.system(size: 13))
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("2.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.accentColor)
                        Text("Copy the bot token and paste it below")
                            .font(.system(size: 13))
                    }
                }

                // Token input
                HStack(spacing: 8) {
                    Group {
                        if isTelegramVisible {
                            TextField("123456:ABC-DEF...", text: $telegramToken)
                        } else {
                            SecureField("123456:ABC-DEF...", text: $telegramToken)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        isTelegramVisible.toggle()
                    } label: {
                        Image(systemName: isTelegramVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                // Connect button + result
                HStack(spacing: 12) {
                    Button {
                        testTelegramConnection()
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingTelegram {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Connect")
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingTelegram)

                    if let botName = telegramBotName {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected as @\(botName)")
                                .foregroundColor(.green)
                        }
                        .font(.system(size: 12, weight: .medium))
                    }

                    Spacer()
                }

                if let error = telegramError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .frame(maxWidth: 440)

            Button {
                telegramSkipped = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep += 1
                }
            } label: {
                Text("Skip for now")
                    .font(.system(size: 13))
            }
            .buttonStyle(.link)

            Spacer()
        }
    }

    private func testTelegramConnection() {
        let trimmed = telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isTestingTelegram = true
        telegramError = nil
        telegramBotName = nil

        Task {
            do {
                let username = try await TelegramService.shared.validateToken(trimmed)
                await MainActor.run {
                    isTestingTelegram = false
                    telegramBotName = username
                    telegramError = nil
                    // Save token on successful test
                    KeychainService.shared.setTelegramToken(trimmed)
                }
            } catch {
                await MainActor.run {
                    isTestingTelegram = false
                    telegramBotName = nil
                    telegramError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Step 5: Your Vault

    private var vaultStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "book.closed.fill")
                .font(.system(size: 56))
                .foregroundStyle(.linearGradient(
                    colors: [.purple, .indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(spacing: 8) {
                Text("Your Memory Vault")
                    .font(.system(size: 26, weight: .bold))

                Text("Cyclop One remembers everything in a local markdown vault.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 16) {
                // Vault info
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.purple.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 17))
                                .foregroundColor(.purple)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vault Location")
                                .font(.system(size: 14, weight: .semibold))
                            Text(vaultDisplayPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text("\(vaultFileCount) files")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            let path = MemoryService.shared.vaultRootPath
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                Text("Open in Finder")
                            }
                            .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            chooseVaultFolder()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: 11))
                                Text("Choose Folder")
                            }
                            .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.controlBackgroundColor))
                )

                // Plugins info
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 17))
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Plugins")
                                .font(.system(size: 14, weight: .semibold))
                            Text("~/.cyclopone/plugins/")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text("\(pluginCount) loaded")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    if !pluginNames.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(pluginNames, id: \.self) { name in
                                HStack(spacing: 6) {
                                    Image(systemName: "puzzlepiece")
                                        .font(.system(size: 9))
                                        .foregroundColor(.orange.opacity(0.7))
                                    Text(name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary.opacity(0.8))
                                }
                            }
                        }
                        .padding(.leading, 48)
                    } else {
                        Text("No plugins installed. Drop plugin folders into ~/.cyclopone/plugins/ to extend Cyclop One.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.leading, 48)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.controlBackgroundColor))
                )
            }
            .frame(maxWidth: 440)

            Spacer()
        }
        .onAppear {
            loadVaultStats()
        }
    }

    private var vaultDisplayPath: String {
        if !customVaultPath.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if customVaultPath.hasPrefix(home) {
                return "~" + customVaultPath.dropFirst(home.count) + "/"
            }
            return customVaultPath + "/"
        }
        return "~/Documents/CyclopOne/"
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Vault Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            customVaultPath = url.path
            // Reload vault stats for the new location
            loadVaultStats()
        }
    }

    private func loadVaultStats() {
        // Count vault files using current vault root
        let vaultURL: URL
        if !customVaultPath.isEmpty {
            vaultURL = URL(fileURLWithPath: customVaultPath)
        } else {
            vaultURL = MemoryService.defaultVaultURL()
        }

        if let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            var count = 0
            while enumerator.nextObject() != nil {
                count += 1
            }
            vaultFileCount = count
        }

        // Load plugin names
        Task {
            let names = await SkillRegistry.shared.pluginNames
            let count = names.count
            await MainActor.run {
                pluginCount = count
                pluginNames = names
            }
        }
    }

    // MARK: - Step 6: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.15), .blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.linearGradient(
                        colors: [.green, .teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }

            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.system(size: 28, weight: .bold))

                Text("Cyclop One is configured and ready to automate your desktop.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Summary checklist
            VStack(spacing: 8) {
                SummaryRow(
                    title: "API Key",
                    icon: apiTestPassed ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: apiTestPassed ? .green : .yellow,
                    detail: apiTestPassed ? "Connected" : "Not tested"
                )
                SummaryRow(
                    title: "Permissions",
                    icon: (accessibilityGranted && screenRecordingGranted) ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: (accessibilityGranted && screenRecordingGranted) ? .green : .yellow,
                    detail: (accessibilityGranted && screenRecordingGranted) ? "All granted" : "Incomplete"
                )
                SummaryRow(
                    title: "Model",
                    icon: "info.circle.fill",
                    color: .blue,
                    detail: modelDisplayName(selectedModel)
                )
                SummaryRow(
                    title: "Telegram",
                    icon: telegramBotName != nil ? "checkmark.circle.fill" : "minus.circle.fill",
                    color: telegramBotName != nil ? .green : .secondary,
                    detail: telegramBotName.map { "@\($0)" } ?? "Skipped"
                )
                SummaryRow(
                    title: "Memory Vault",
                    icon: "checkmark.circle.fill",
                    color: .green,
                    detail: "\(vaultFileCount) files"
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .frame(maxWidth: 420)

            // Example commands
            VStack(alignment: .leading, spacing: 8) {
                Text("Try these commands:")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)

                ExampleCommand("Open Calculator and type 123")
                ExampleCommand("Take a screenshot and describe what you see")
                ExampleCommand("Open Safari and search for Swift tutorials")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .frame(maxWidth: 420)

            Spacer()
        }
        .onAppear {
            refreshPermissions()
            loadVaultStats()
        }
    }

    private func modelDisplayName(_ id: String) -> String {
        switch id {
        case "claude-opus-4-6": return "Opus 4.6"
        case "claude-sonnet-4-6": return "Sonnet 4.6"
        case "claude-haiku-4-5": return "Haiku 4.5"
        default: return id
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if currentStep > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep -= 1
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button {
                    advanceStep()
                } label: {
                    HStack(spacing: 4) {
                        Text("Continue")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            } else {
                Button {
                    onComplete()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Get Started")
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Navigation Logic

    private var canAdvance: Bool {
        switch currentStep {
        case 0: return true
        case 1: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 2: return accessibilityGranted && screenRecordingGranted
        case 3: return true  // Always has a default model
        case 4: return true  // Optional step
        case 5: return true  // Info only
        case 6: return true
        default: return true
        }
    }

    private func advanceStep() {
        switch currentStep {
        case 1:
            // Validate and save API key before advancing
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                apiKeyError = "Please enter your API key."
                return
            }
            guard trimmed.hasPrefix("sk-ant-") else {
                apiKeyError = "Key should start with 'sk-ant-'. Please check your key."
                return
            }
            if KeychainService.shared.setAPIKey(trimmed) {
                apiKeyError = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentStep += 1
                }
            } else {
                apiKeyError = "Failed to save key to Keychain."
            }

        default:
            withAnimation(.easeInOut(duration: 0.2)) {
                currentStep += 1
            }
        }
    }

    // MARK: - Permission Helpers

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshPermissions()
            }
        }
    }
}

// MARK: - ModelCard

struct ModelCard: View {
    let modelID: String
    let name: String
    let badge: String?
    let description: String
    let cost: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.12))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)

                        if let badge = badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor)
                                )
                        }
                    }

                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(cost)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.4))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SummaryRow

struct SummaryRow: View {
    let title: String
    let icon: String
    let color: Color
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Subviews

struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct ExampleCommand: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundColor(.accentColor.opacity(0.7))

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
    }
}
