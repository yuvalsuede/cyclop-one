import SwiftUI

/// The visual status that the floating dot can display.
/// Maps from AgentState but provides a simpler, color-focused abstraction.
/// The dot renders as a glowing eye with iris, pupil, and specular highlight.
enum DotStatus: Equatable {
    case idle           // blue, steady glow
    case listening      // green, pulse animation
    case working        // amber, spinning animation
    case verifying      // cyan, pulse animation
    case needsApproval  // red, pulse animation
    case done           // green, steady
    case error          // red, steady

    /// Map from AgentState to DotStatus.
    static func from(_ agentState: AgentState) -> DotStatus {
        switch agentState {
        case .idle:
            return .idle
        case .listening:
            return .listening
        case .capturing, .thinking, .executing:
            return .working
        case .awaitingConfirmation:
            return .needsApproval
        case .done:
            return .done
        case .error:
            return .error
        }
    }

    var color: Color {
        switch self {
        case .idle:          return .blue
        case .listening:     return .green
        case .working:       return .orange
        case .verifying:     return .cyan
        case .needsApproval: return .red
        case .done:          return .green
        case .error:         return .red
        }
    }

    var shouldPulse: Bool {
        switch self {
        case .listening, .verifying, .needsApproval: return true
        default: return false
        }
    }

    var shouldSpin: Bool {
        switch self {
        case .working: return true
        default: return false
        }
    }

    /// Pupil diameter in points. Dilates when working, constricts on error/approval.
    var pupilSize: CGFloat {
        switch self {
        case .idle:          return 12
        case .listening:     return 14
        case .working:       return 18
        case .verifying:     return 14
        case .needsApproval: return 10
        case .done:          return 12
        case .error:         return 8
        }
    }

    /// Short label shown next to the eye during activity.
    var activityLabel: String? {
        switch self {
        case .idle, .done:   return nil
        case .listening:     return "Listening"
        case .working:       return "Working"
        case .verifying:     return "Verifying"
        case .needsApproval: return "Approve?"
        case .error:         return "Error"
        }
    }
}

// MARK: - Eye View

/// A 48px circular SwiftUI view styled as a glowing eye.
/// The iris color reflects status, the pupil dilates/constricts by state,
/// and a specular highlight gives it depth. Blinks occasionally.
struct EyeView: View {
    let status: DotStatus
    let size: CGFloat = 48
    var isRecording: Bool = false

    @State private var pulseScale: CGFloat = 1.0
    @State private var spinAngle: Double = 0.0
    @State private var glowOpacity: Double = 0.6
    @State private var recordingPulse: CGFloat = 1.0
    @State private var animatedPupilSize: CGFloat = 12
    @State private var blinkScaleY: CGFloat = 1.0
    @State private var blinkTimer: Timer?

    private let irisSize: CGFloat = 28

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .stroke(Color.orange, lineWidth: 3)
                    .frame(width: size + 14, height: size + 14)
                    .scaleEffect(recordingPulse)
                    .shadow(color: Color.orange.opacity(0.5), radius: 6)
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: size + 14, height: size + 14)
                    .scaleEffect(recordingPulse)
            }

            Circle()
                .fill(status.color.opacity(0.25))
                .frame(width: size + 8, height: size + 8)
                .scaleEffect(pulseScale)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [.white, Color(white: 0.92)]),
                            center: .center, startRadius: 0, endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                    .shadow(color: status.color.opacity(glowOpacity), radius: 8, x: 0, y: 2)

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                status.color.opacity(0.5),
                                status.color.opacity(0.9)
                            ]),
                            center: .center, startRadius: 2, endRadius: irisSize / 2
                        )
                    )
                    .frame(width: irisSize, height: irisSize)

                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color(white: 0.05), Color(white: 0.15)
                            ]),
                            center: .center, startRadius: 0, endRadius: animatedPupilSize / 2
                        )
                    )
                    .frame(width: animatedPupilSize, height: animatedPupilSize)

                if status.shouldSpin {
                    Circle()
                        .trim(from: 0.0, to: 0.3)
                        .stroke(Color.white.opacity(0.8), lineWidth: 2.5)
                        .frame(width: irisSize + 6, height: irisSize + 6)
                        .rotationEffect(.degrees(spinAngle))
                }

                Circle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .offset(x: 3, y: -3)
            }
            .scaleEffect(x: 1.0, y: blinkScaleY)
            .clipShape(Circle())
        }
        .frame(width: size + 14, height: size + 14)
        .id(status)
        .onChange(of: isRecording) { _, recording in
            updateRecordingAnimation(recording)
        }
        .onAppear {
            animatedPupilSize = status.pupilSize
            updateAnimations(for: status)
            updateRecordingAnimation(isRecording)
            startBlinkTimer()
        }
        .onDisappear {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        scheduleNextBlink()
    }

    private func scheduleNextBlink() {
        let interval = Double.random(in: 3.0...7.0)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            DispatchQueue.main.async { performBlink() }
        }
    }

    private func performBlink() {
        withAnimation(.easeIn(duration: 0.08)) { blinkScaleY = 0.08 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.12)) { blinkScaleY = 1.0 }
            scheduleNextBlink()
        }
    }

    private func updateAnimations(for newStatus: DotStatus) {
        withAnimation(.default) { pulseScale = 1.0; glowOpacity = 0.6 }
        withAnimation(.easeInOut(duration: 0.4)) { animatedPupilSize = newStatus.pupilSize }

        if newStatus.shouldPulse {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.15; glowOpacity = 0.9
            }
        }

        if newStatus.shouldSpin {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        } else {
            spinAngle = 0
        }
    }

    private func updateRecordingAnimation(_ recording: Bool) {
        if recording {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                recordingPulse = 1.08
            }
        } else {
            withAnimation(.default) { recordingPulse = 1.0 }
        }
    }
}

// DotStatusView removed — FloatingDot now uses EyeView directly
// with a separate StatusLabelWindow for status display.
