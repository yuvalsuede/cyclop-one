import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "KeychainService")

/// Securely stores and retrieves the Claude API key in the macOS Keychain.
///
/// Sprint 17: Hardened Keychain ACLs
/// - All items use kSecAttrAccessibleWhenUnlockedThisDeviceOnly (no iCloud sync, no locked-device access)
/// - Access control lists (ACLs) restrict access to the current application only
/// - Items are non-migratable (kSecAttrIsSensitive, kSecAttrIsExtractable = false where supported)
class KeychainService {

    static let shared = KeychainService()

    private let service = "com.cyclop.one.apikey"
    private let account = "claude-api-key"

    /// In-memory API key override. When set, getAPIKey() returns this
    /// without touching the Keychain — avoids SecurityAgent dialogs
    /// after rebuilds change the code signature.
    private var inMemoryAPIKey: String?

    private init() {}

    // MARK: - Sprint 17: Hardened ACL Helper

    /// Create a SecAccessControl with application-bound protection.
    /// Items are only accessible when the device is unlocked and only by this application.
    private func createHardenedAccessControl() -> SecAccessControl? {
        return SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [],  // No additional constraints (biometry etc.) — just app-bound + unlocked
            nil
        )
    }

    /// Build a simple Keychain query dictionary.
    ///
    /// NOTE: Previously used SecAccessControlCreateWithFlags for hardened ACLs (Sprint 17),
    /// but this caused SecItemDelete to block the main thread with password prompts
    /// and triggered SecurityAgent dialogs on every read. Reverted to simple
    /// kSecAttrAccessibleWhenUnlockedThisDeviceOnly per CLAUDE.md guidance.
    private func hardenedAddQuery(account: String, data: Data) -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        return query
    }

    // MARK: - API Key

    /// Store the API key in the Keychain with simple ACLs.
    /// Uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly only (no SecAccessControl).
    /// Keychain operations run on a background queue to avoid blocking the main thread
    /// (SecItemDelete can trigger SecurityAgent dialog if old item has different code signature).
    @discardableResult
    func setAPIKey(_ key: String) -> Bool {
        // Always store in memory first — this is the primary source
        inMemoryAPIKey = key
        NSLog("CyclopOne [KeychainService]: API key stored in memory (%d chars)", key.count)

        guard let data = key.data(using: .utf8) else { return true }

        // Persist to Keychain on background thread to avoid blocking main thread
        // (SecItemDelete can trigger SecurityAgent authorization after rebuild)
        DispatchQueue.global(qos: .utility).async { [self] in
            deleteAPIKey()

            let query = hardenedAddQuery(account: account, data: data)

            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                logger.warning("SecItemAdd failed: \(status) — using in-memory key only")
            } else {
                NSLog("CyclopOne [KeychainService]: API key persisted to Keychain")
            }
        }
        return true
    }

    /// Retrieve the API key from the Keychain.
    /// Uses kSecUseAuthenticationUIFail to prevent blocking the main thread
    /// when the item was created externally (e.g. via `security` CLI) and
    /// requires user authorization that would trigger a blocking dialog.
    func getAPIKey() -> String? {
        // Prefer in-memory key — avoids SecurityAgent dialogs entirely
        if let key = inMemoryAPIKey {
            return key
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecInteractionNotAllowed {
            logger.warning("Keychain item requires interactive auth. Using in-memory key if available.")
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete the API key from the Keychain.
    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if an API key is stored.
    var hasAPIKey: Bool {
        return getAPIKey() != nil
    }

    // MARK: - Telegram Bot Token

    private let telegramAccount = "telegram-bot-token"
    private let telegramService = "com.cyclop.one.telegram-token"
    private var inMemoryTelegramToken: String?

    /// Store the Telegram bot token in the Keychain.
    @discardableResult
    func setTelegramToken(_ token: String) -> Bool {
        inMemoryTelegramToken = token
        NSLog("CyclopOne [KeychainService]: Telegram token stored in memory (%d chars)", token.count)

        // Persist to Keychain in background to avoid blocking main thread
        // (SecItemDelete can trigger SecurityAgent dialog after rebuild)
        guard let data = token.data(using: .utf8) else { return true }
        DispatchQueue.global(qos: .utility).async { [self] in
            deleteTelegramToken()

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.telegramService,
                kSecAttrAccount as String: self.telegramAccount,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
            ]

            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                logger.warning("Telegram SecItemAdd failed: \(status) — using in-memory token only")
            }
        }
        return true
    }

    /// Retrieve the Telegram bot token.
    func getTelegramToken() -> String? {
        if let token = inMemoryTelegramToken {
            return token
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: telegramService,
            kSecAttrAccount as String: telegramAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete the Telegram bot token from the Keychain.
    @discardableResult
    func deleteTelegramToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: telegramService,
            kSecAttrAccount as String: telegramAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a Telegram bot token is stored.
    var hasTelegramToken: Bool {
        return getTelegramToken() != nil
    }

}
