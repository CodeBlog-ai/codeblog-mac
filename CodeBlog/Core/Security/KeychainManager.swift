//
//  KeychainManager.swift
//  CodeBlog
//

import Foundation
import Security

/// Thread-safe manager for securely storing API keys in macOS Keychain.
///
/// Uses Data Protection Keychain (`kSecUseDataProtectionKeychain`) to avoid
/// system permission popups during development with "Sign to Run Locally".
final class KeychainManager {

    static let shared = KeychainManager()

    private let servicePrefix = "com.teleportlabs.codeblog.apikeys"
    private let queue = DispatchQueue(label: "com.teleportlabs.codeblog.keychain", qos: .userInitiated)

    private init() {}

    // MARK: - Public API

    /// Stores an API key in the keychain
    @discardableResult
    func store(_ apiKey: String, for provider: String) -> Bool {
        return queue.sync {
            guard let data = apiKey.data(using: .utf8) else { return false }

            let service = "\(servicePrefix).\(provider)"

            // Delete any existing item first
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecUseDataProtectionKeychain as String: true
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            // Add new item using Data Protection Keychain (no popup)
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                kSecUseDataProtectionKeychain as String: true
            ]

            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                print("[KeychainManager] store failed for '\(provider)': \(status)")
            }
            return status == errSecSuccess
        }
    }

    /// Retrieves an API key from the keychain
    func retrieve(for provider: String) -> String? {
        return queue.sync {
            let service = "\(servicePrefix).\(provider)"

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: true
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess,
                  let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8) else {
                return nil
            }

            return apiKey
        }
    }

    /// Deletes an API key from the keychain
    @discardableResult
    func delete(for provider: String) -> Bool {
        return queue.sync {
            let service = "\(servicePrefix).\(provider)"

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: provider,
                kSecUseDataProtectionKeychain as String: true
            ]

            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }

    /// Checks if an API key exists in the keychain
    func exists(for provider: String) -> Bool {
        return retrieve(for: provider) != nil
    }
}
