import Foundation
import Security

struct SlackCredentials: Sendable {
    let botToken: String
    let appToken: String
}

protocol SlackCredentialStoring: Sendable {
    func save(_ credentials: SlackCredentials) throws
    func load() throws -> SlackCredentials
}

/// Exact generic-password items in the selected installation's Keychain service.
/// Errors deliberately contain only OSStatus values, never token contents.
struct SlackKeychainCredentialStore: SlackCredentialStoring {
    let service: String

    func save(_ credentials: SlackCredentials) throws {
        try put(credentials.botToken, account: "bot-token")
        try put(credentials.appToken, account: "app-token")
    }

    func load() throws -> SlackCredentials {
        SlackCredentials(botToken: try get("bot-token"), appToken: try get("app-token"))
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func put(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = base(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // Use the macOS login Keychain; this app does not require a
            // data-protection Keychain access-group entitlement.
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw SlackCredentialError.keychain(inserted) }
        } else if status != errSecSuccess { throw SlackCredentialError.keychain(status) }
    }

    private func get(_ account: String) throws -> String {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw SlackCredentialError.keychain(status)
        }
        return value
    }
}

enum SlackCredentialError: LocalizedError {
    case keychain(OSStatus), invalid
    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Keychain could not read or save Slack credentials (status \(status))."
        case .invalid: return "Enter both Slack tokens without whitespace."
        }
    }
}
