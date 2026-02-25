import SwiftUI

// MARK: - SkillApprovalSheet

/// Sheet presented to the user before activating a newly installed skill.
/// For HIGH risk skills, the user must type "APPROVE" to confirm.
struct SkillApprovalSheet: View {
    let package: SkillPackage
    let scanResult: SkillSafetyScanner.ScanResult
    let onApprove: () -> Void
    let onCancel: () -> Void

    @State private var confirmText = ""

    private var isHighRisk: Bool {
        scanResult.riskLevel == .high
    }

    private var canApprove: Bool {
        if isHighRisk {
            return confirmText.trimmingCharacters(in: .whitespaces).uppercased() == "APPROVE"
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("v\(package.manifest.version)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                RiskBadge(level: scanResult.riskLevel)
            }

            Divider()

            // Permissions
            if let permissions = package.manifest.permissions, !permissions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requested Permissions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    ForEach(permissions, id: \.self) { perm in
                        HStack(spacing: 6) {
                            Image(systemName: permissionIcon(perm))
                                .font(.system(size: 11))
                                .foregroundColor(permissionColor(perm))
                                .frame(width: 16)
                            Text(perm.capitalized)
                                .font(.system(size: 11))
                        }
                    }
                }
            }

            // Findings
            if !scanResult.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Safety Findings (\(scanResult.findings.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    ForEach(Array(scanResult.findings.prefix(5).enumerated()), id: \.offset) { _, finding in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: findingIcon(finding.severity))
                                .font(.system(size: 9))
                                .foregroundColor(findingColor(finding.severity))
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.description)
                                    .font(.system(size: 10))
                                    .lineLimit(2)
                                if let line = finding.line {
                                    Text("\(finding.file):\(line)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    if scanResult.findings.count > 5 {
                        Text("...and \(scanResult.findings.count - 5) more findings")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // HIGH risk confirmation
            if isHighRisk {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("This skill has HIGH risk findings. Type APPROVE to confirm.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red)
                    }
                    TextField("Type APPROVE to confirm", text: $confirmText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Button(action: {
                    if canApprove { onApprove() }
                }) {
                    Label("Approve & Enable", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canApprove)
                .tint(isHighRisk ? .red : .green)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Private helpers

    private func permissionIcon(_ perm: String) -> String {
        switch perm.lowercased() {
        case "network":    return "network"
        case "filesystem": return "folder"
        case "shell":      return "terminal"
        case "camera":     return "camera"
        case "microphone": return "mic"
        default:           return "key"
        }
    }

    private func permissionColor(_ perm: String) -> Color {
        switch perm.lowercased() {
        case "network":    return .blue
        case "filesystem": return .orange
        case "shell":      return .red
        default:           return .secondary
        }
    }

    private func findingIcon(_ level: SkillSafetyScanner.RiskLevel) -> String {
        switch level {
        case .high:   return "xmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low:    return "info.circle.fill"
        case .safe:   return "checkmark.circle.fill"
        }
    }

    private func findingColor(_ level: SkillSafetyScanner.RiskLevel) -> Color {
        switch level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        case .safe:   return .green
        }
    }
}

// MARK: - RiskBadge

/// Colored badge showing a risk level.
struct RiskBadge: View {
    let level: SkillSafetyScanner.RiskLevel

    var body: some View {
        Text(level.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch level {
        case .safe:   return .green
        case .low:    return .yellow
        case .medium: return .orange
        case .high:   return .red
        }
    }
}
