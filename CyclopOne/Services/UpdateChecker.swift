import Foundation
import AppKit

/// Checks for app updates by fetching a JSON manifest from cyclop.one.
///
/// The manifest is expected at `https://cyclop.one/api/version.json` with format:
/// ```json
/// { "version": "0.2.0", "build": 2, "url": "https://cyclop.one/download", "notes": "Bug fixes" }
/// ```
///
/// Checks automatically on launch (throttled to once per 24 hours) and on demand
/// via the status bar menu "Check for Updates..." item.
actor UpdateChecker {

    static let shared = UpdateChecker()

    private let manifestURL = URL(string: "https://cyclop.one/api/version.json")!
    private let checkIntervalSeconds: TimeInterval = 24 * 60 * 60 // 24 hours

    struct VersionManifest: Decodable {
        let version: String
        let build: Int?
        let url: String?
        let notes: String?
    }

    // MARK: - Public API

    /// Check for updates automatically (throttled to once per checkInterval).
    func checkOnLaunch() async {
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        guard now - lastCheck > checkIntervalSeconds else {
            NSLog("CyclopOne [UpdateChecker]: Skipping — last check was %.0f minutes ago", (now - lastCheck) / 60)
            return
        }
        await performCheck(userInitiated: false)
    }

    /// Check for updates immediately (user clicked "Check for Updates").
    func checkNow() async {
        await performCheck(userInitiated: true)
    }

    // MARK: - Private

    private func performCheck(userInitiated: Bool) async {
        NSLog("CyclopOne [UpdateChecker]: Checking for updates (userInitiated=%d)", userInitiated ? 1 : 0)

        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("CyclopOne [UpdateChecker]: Server returned %d", code)
                if userInitiated {
                    await showNoUpdateAlert(message: "Could not reach update server (HTTP \(code)).")
                }
                return
            }

            let manifest = try JSONDecoder().decode(VersionManifest.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            if isNewer(manifest.version, than: currentVersion) {
                NSLog("CyclopOne [UpdateChecker]: Update available — %@ → %@", currentVersion, manifest.version)
                await showUpdateAvailableAlert(
                    current: currentVersion,
                    latest: manifest.version,
                    notes: manifest.notes,
                    downloadURL: manifest.url
                )
            } else {
                NSLog("CyclopOne [UpdateChecker]: Up to date (%@)", currentVersion)
                if userInitiated {
                    await showNoUpdateAlert(message: "You're running the latest version (\(currentVersion)).")
                }
            }
        } catch {
            NSLog("CyclopOne [UpdateChecker]: Error — %@", error.localizedDescription)
            if userInitiated {
                await showNoUpdateAlert(message: "Could not check for updates: \(error.localizedDescription)")
            }
        }
    }

    /// Semantic version comparison: true if `latest` > `current`.
    private func isNewer(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }

    // MARK: - UI

    @MainActor
    private func showUpdateAvailableAlert(current: String, latest: String, notes: String?, downloadURL: String?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Cyclop One \(latest) is available (you have \(current))."
        if let notes = notes {
            alert.informativeText += "\n\n\(notes)"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let urlStr = downloadURL, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @MainActor
    private func showNoUpdateAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Software Update"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
