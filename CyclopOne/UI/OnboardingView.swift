import SwiftUI

/// Redesigned first-launch onboarding wizard for Cyclop One.
///
/// Four-step flow:
/// 1. Welcome — what Cyclop One is and what it does
/// 2. API Key — enter and save Claude API key
/// 3. Permissions — check/request Accessibility and Screen Recording
/// 4. Ready — congratulations, get started
struct OnboardingView: View {
    @EnvironmentObject var coordinator: AgentCoordinator

    let onComplete: () -> Void

    @State private var currentStep = 0
    private let totalSteps = 4

    // Step 2: API key
    @State private var apiKey: String = ""
    @State private var apiKeyError: String?
    @State private var isKeyVisible = false

    // Step 3: Permissions
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var permissionCheckTimer: Timer?

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
                case 3: readyStep
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
        .frame(width: 560, height: 620)
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
                // Circle with number or checkmark
                ZStack {
                    Circle()
                        .fill(step < currentStep ? Color.accentColor : (step == currentStep ? Color.accentColor : Color.secondary.opacity(0.2)))
                        .frame(width: 32, height: 32)

                    if step < currentStep {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(step + 1)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(step == currentStep ? .white : .secondary)
                    }
                }

                // Connector line
                if step < totalSteps - 1 {
                    Rectangle()
                        .fill(step < currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Step 1: Welcome

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

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(spacing: 24) {
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

                if let error = apiKeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
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

    // MARK: - Step 3: Permissions

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
                // Accessibility
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

                // Screen Recording
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
            // Status icon
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

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 24) {
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
                    .frame(width: 120, height: 120)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.linearGradient(
                        colors: [.green, .teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }

            VStack(spacing: 10) {
                Text("You're All Set!")
                    .font(.system(size: 28, weight: .bold))

                Text("Cyclop One is configured and ready to automate your desktop. Give it a command and watch it work.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Try these commands:")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)

                ExampleCommand("Open Calculator and type 123")
                ExampleCommand("Take a screenshot and describe what you see")
                ExampleCommand("Open Safari and search for Swift tutorials")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.controlBackgroundColor))
            )
            .frame(maxWidth: 420)

            Spacer()
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
        case 0: return true  // Welcome: always can continue
        case 1: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 2: return accessibilityGranted && screenRecordingGranted
        case 3: return true
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
