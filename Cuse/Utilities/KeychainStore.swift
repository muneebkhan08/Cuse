//
//  KeychainStore.swift
//  Cuse
//
//  Minimal Keychain helper for storing sensitive strings (like API keys)
//  that shouldn't live in UserDefaults. Uses kSecClassGenericPassword —
//  the standard macOS pattern for service-scoped secrets.
//
//  Scoped to Cuse's bundle identifier so the entries are isolated
//  from other services. No iCloud sync — these are device-local keys only.
//

import Foundation
import Security

enum KeychainStore {

    private static let serviceName: String = Bundle.main.bundleIdentifier ?? "com.muneebkhan.cuse"

    /// What the Keychain holds for a key, checked without any password prompt.
    enum StoredKeyStatus: Equatable {
        /// Nothing saved.
        case missing
        /// Saved and readable by this build.
        case readable
        /// Saved by an older or differently signed Cuse build. macOS would
        /// only release it after the login password, so Cuse treats it as
        /// unusable and asks for the key to be pasted once more.
        case savedByOlderBuild
    }

    /// Values already decrypted or saved during this launch, so each key is
    /// read from the Keychain at most once instead of on every Combined step.
    private static var valuesReadThisLaunch: [String: String] = [:]

    /// Runs Keychain work with password prompts switched off.
    ///
    /// The login keychain ignores per-query "no UI" options
    /// (`kSecUseAuthenticationUIFail`, `LAContext.interactionNotAllowed`); with
    /// those, an untrusted read still blocks the app on a password dialog.
    /// This process-wide switch is the only setting that makes the read fail
    /// immediately instead. It is deprecated but still honoured by macOS.
    private static func withPasswordPromptsDisabled<Result>(_ keychainWork: () -> Result) -> Result {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return keychainWork()
    }

    private static func itemQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
    }

    /// Write (or overwrite) a UTF-8 string for the given key. Returns
    /// true on success. Empty / whitespace-only input is treated as a
    /// delete so callers can implement "clear the key" as just writing
    /// an empty string.
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(forKey: key)
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let didSave = withPasswordPromptsDisabled { () -> Bool in
            // Delete then add instead of updating in place. An update keeps the
            // item's old access list, so a key first saved by an older build
            // would stay unreadable. Deleting needs no password, and the freshly
            // added item trusts this signed app and later same-team rebuilds.
            let deleteStatus = SecItemDelete(itemQuery(forKey: key) as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { return false }

            var addQuery = itemQuery(forKey: key)
            addQuery[kSecValueData as String] = data
            // Only accessible after the device has been unlocked (standard
            // behavior for a Mac app — keys shouldn't leak to background
            // processes on a locked machine).
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        if didSave { valuesReadThisLaunch[key] = trimmed }
        return didSave
    }

    /// Read the stored UTF-8 string for the given key. Never shows a password
    /// prompt: returns nil when nothing is saved or when the saved item belongs
    /// to an older build (see `status(forKey:)`).
    static func get(forKey key: String) -> String? {
        if let cachedValue = valuesReadThisLaunch[key] {
            return cachedValue
        }

        var query = itemQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = withPasswordPromptsDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        valuesReadThisLaunch[key] = string
        return string
    }

    /// Whether a key is saved and usable, checked without a password prompt.
    static func status(forKey key: String) -> StoredKeyStatus {
        if let value = get(forKey: key) {
            return value.isEmpty ? .missing : .readable
        }
        // Reading attributes never needs the password, so this tells an
        // unreadable old item apart from no item at all.
        var query = itemQuery(forKey: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let attributesStatus = withPasswordPromptsDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        return attributesStatus == errSecSuccess ? .savedByOlderBuild : .missing
    }

    /// True only when a key is saved and this build can read it without a prompt.
    static func hasValue(forKey key: String) -> Bool {
        status(forKey: key) == .readable
    }

    /// Delete the item for the given key. Returns true if deleted OR
    /// if there was nothing to delete (either is "success" from the
    /// caller's perspective — the key is gone).
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let status = withPasswordPromptsDisabled {
            SecItemDelete(itemQuery(forKey: key) as CFDictionary)
        }
        let isGone = status == errSecSuccess || status == errSecItemNotFound
        if isGone { valuesReadThisLaunch[key] = nil }
        return isGone
    }

    // MARK: - Cuse-specific keys

    /// Gemini API key the user has pasted directly into the app.
    static var geminiAPIKey: String? {
        get { get(forKey: "geminiAPIKey") }
        set { set(newValue ?? "", forKey: "geminiAPIKey") }
    }

    /// Unused by local Laya. Kept so an older saved value can still be removed.
    static var jevAPIKey: String? {
        get { get(forKey: "jevAPIKey") }
        set { set(newValue ?? "", forKey: "jevAPIKey") }
    }

}
