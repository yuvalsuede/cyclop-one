import AppKit
import SwiftUI
import Combine

// MARK: - Popover Content View

/// Popover shown when the user clicks the floating dot.
/// Shows status, command input, stop button.
struct DotPopoverView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @State private var commandText = ""
    @FocusState private var isCommandFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(coordinator.state.displayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                if coordinator.state.isActive {
                    Button(action: {
                        coordinator.cancel()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop current task (or press Esc)")
                }
            }

            // Current task summary
            if let lastMessage = coordinator.messages.last(where: { $0.role == .assistant && !$0.isLoading && !$0.content.isEmpty }) {
                Text(lastMessage.content)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
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

            // Token count
            Text("\(coordinator.totalTokensUsed) tokens used")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { isCommandFocused = true }
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

// MARK: - Status Label Window

/// A separate floating window that shows the current agent status above the eye.
/// Appears when the agent is active, hides when idle.
@MainActor
class StatusLabelWindow: NSPanel {

    private var hostingView: NSHostingView<StatusLabelView>!
    private let labelWidth: CGFloat = 200
    private let labelHeight: CGFloat = 44

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true

        let view = StatusLabelView(text: "", color: .blue, onCancel: {})
        hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: labelWidth, height: labelHeight)
        contentView = hostingView
    }

    func update(text: String, color: Color, onCancel: @escaping () -> Void) {
        hostingView.rootView = StatusLabelView(text: text, color: color, onCancel: onCancel)
    }

    /// Position this label above the given eye panel frame.
    func positionAbove(eyeFrame: NSRect) {
        let x = eyeFrame.midX - labelWidth / 2
        let y = eyeFrame.maxY + 4
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// SwiftUI view for the floating status label.
struct StatusLabelView: View {
    let text: String
    let color: Color
    let onCancel: () -> Void

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: 6) {
                // Animated status dot
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // Cancel button
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.black.opacity(0.8))
                    .shadow(color: color.opacity(0.3), radius: 6)
            )
            .frame(maxWidth: 200)
        }
    }
}

// MARK: - FloatingDot NSPanel

/// A 48px circular floating dot that acts as the primary UI for Cyclop One.
/// Stays on top of all windows. Click opens a popover, drag repositions,
/// right-click shows context menu.
/// A separate StatusLabelWindow floats above it showing what the agent is doing.
@MainActor
class FloatingDot: NSPanel {

    // MARK: - Properties

    private let dotSize: CGFloat = 48
    private let panelSize: CGFloat = 64
    private var hostingView: NSHostingView<EyeView>!
    private var statusCancellable: AnyCancellable?
    private var popover: NSPopover?
    private weak var coordinator: AgentCoordinator?
    private var isRecordingActive = false

    /// Separate window for status label above the eye.
    private var statusLabel: StatusLabelWindow?

    /// Track drag state
    private var isDragging = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero

    // MARK: - Initialization

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        setupDotView(coordinator: coordinator)
        setupStatusLabel()
        positionOnScreen()
        subscribeToStateChanges(coordinator: coordinator)
        subscribeToRecordingState()
        configureAccessibility()
    }

    // MARK: - Panel Configuration

    private func configurePanel() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = true
    }

    // MARK: - Dot View

    private func setupDotView(coordinator: AgentCoordinator) {
        let dotView = EyeView(status: .idle)
        hostingView = NSHostingView(rootView: dotView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        contentView = hostingView
    }

    // MARK: - Status Label

    private func setupStatusLabel() {
        statusLabel = StatusLabelWindow()
        statusLabel?.orderFront(nil)
        statusLabel?.alphaValue = 0 // Start hidden
    }

    // MARK: - State Subscription

    private func subscribeToStateChanges(coordinator: AgentCoordinator) {
        statusCancellable = coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                let dotStatus = DotStatus.from(newState)
                self.updateEye(dotStatus)
                self.updateStatusLabel(newState)
            }
    }

    private func updateEye(_ status: DotStatus) {
        hostingView.rootView = EyeView(status: status, isRecording: isRecordingActive)
    }

    /// Called by AgentCoordinator to update the dot directly.
    func updateDotStatus(_ status: DotStatus) {
        updateEye(status)
    }

    private func updateStatusLabel(_ state: AgentState) {
        guard let label = statusLabel else { return }
        let dotStatus = DotStatus.from(state)

        if state.isActive {
            label.update(
                text: state.displayText,
                color: dotStatus.color,
                onCancel: { [weak self] in self?.coordinator?.cancel() }
            )
            label.ignoresMouseEvents = false
            label.positionAbove(eyeFrame: self.frame)

            if label.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    label.animator().alphaValue = 1
                }
            }
        } else {
            // Fade out
            if label.alphaValue > 0 {
                // Brief delay so "Done" is visible
                let delay: TimeInterval = (state == .done || state == .idle) ? 1.5 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak label] in
                    guard let label = label else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.3
                        label.animator().alphaValue = 0
                    }
                    label.ignoresMouseEvents = true
                }
            }
        }
    }

    // MARK: - Recording State Subscription

    private func subscribeToRecordingState() {
        Task {
            await ScreenCaptureService.shared.setCaptureStateHandler { @MainActor [weak self] isCapturing in
                guard let self = self else { return }
                self.isRecordingActive = isCapturing
                if let coordinator = self.coordinator {
                    self.updateEye(DotStatus.from(coordinator.state))
                }
            }
        }
    }

    // MARK: - Screen Positioning

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 24

        let x = screenFrame.maxX - panelSize - margin
        let y = screenFrame.minY + margin

        setFrameOrigin(NSPoint(x: x, y: y))
        statusLabel?.positionAbove(eyeFrame: self.frame)
    }

    // MARK: - Mouse Events

    override var canBecomeKey: Bool { popover?.isShown == true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = frame.origin

        let myPID = ProcessInfo.processInfo.processIdentifier
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != myPID {
            coordinator?.previousFrontmostPID = frontApp.processIdentifier
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouseLocation = NSEvent.mouseLocation
        let dx = currentMouseLocation.x - dragStartMouseLocation.x
        let dy = currentMouseLocation.y - dragStartMouseLocation.y

        if abs(dx) > 3 || abs(dy) > 3 {
            isDragging = true
        }

        if isDragging {
            let newOrigin = NSPoint(
                x: dragStartWindowOrigin.x + dx,
                y: dragStartWindowOrigin.y + dy
            )
            setFrameOrigin(newOrigin)
            // Move status label with the eye
            statusLabel?.positionAbove(eyeFrame: self.frame)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            togglePopover()
        }
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: event)
    }

    // MARK: - Accessibility

    private func configureAccessibility() {
        setAccessibilityRole(.button)
        setAccessibilityLabel("Cyclop One")
        setAccessibilityEnabled(true)
    }

    override func accessibilityPerformPress() -> Bool {
        togglePopover()
        return true
    }

    // MARK: - Popover

    func dismissPopover() {
        if let existing = popover, existing.isShown {
            existing.close()
        }
        popover = nil
    }

    func allWindowNumbers() -> [Int] {
        var numbers: [Int] = []
        if windowNumber > 0 {
            numbers.append(windowNumber)
        }
        if let pop = popover, pop.isShown,
           let popWindow = pop.contentViewController?.view.window,
           popWindow.windowNumber > 0 {
            numbers.append(popWindow.windowNumber)
        }
        if let labelNum = statusLabel?.windowNumber, labelNum > 0 {
            numbers.append(labelNum)
        }
        return numbers
    }

    func togglePopover() {
        if let existing = popover, existing.isShown {
            existing.close()
            popover = nil
            return
        }

        guard let coordinator = coordinator else { return }
        guard let contentView = contentView else { return }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true

        let popoverView = DotPopoverView(onDismiss: { [weak pop] in
            pop?.close()
        })
        .environmentObject(coordinator)

        pop.contentViewController = NSHostingController(rootView: popoverView)

        pop.show(
            relativeTo: contentView.bounds,
            of: contentView,
            preferredEdge: .minX
        )

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pop.contentViewController?.view.window?.makeKey()
        }

        popover = pop
    }

    // MARK: - Context Menu

    private func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Cyclop One",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        guard let cv = contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: cv)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
