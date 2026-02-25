import SwiftUI

// MARK: - SkillCardView

/// A compact card representing a single marketplace skill entry.
struct SkillCardView: View {
    let entry: SkillMarketplaceClient.MarketplaceSkillEntry
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Category icon
            Image(systemName: SkillCategory.from(entry.category).icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // Name + verified badge
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if entry.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                    }
                    Spacer(minLength: 0)
                }

                // Description
                Text(entry.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Meta row: rating, author, downloads
                HStack(spacing: 6) {
                    if let rating = entry.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("by \(entry.author)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if let dl = entry.downloads {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text(formatDownloads(dl))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // Install button
            Button(action: onInstall) {
                Text(isInstalled ? "Installed" : "Install")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .disabled(isInstalled)
            .tint(isInstalled ? Color.secondary : Color.accentColor)
        }
        .padding(.vertical, 6)
    }

    private func formatDownloads(_ count: Int) -> String {
        if count >= 1000 {
            return "\(count / 1000)k"
        }
        return "\(count)"
    }
}
