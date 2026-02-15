import Foundation
import Security

enum AmazonPhotosCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain error (\(status))"
        }
    }
}

final class AmazonPhotosCredentialStore {
    private struct StoredCredentials: Codable {
        let sessionID: String
        let ubidCookieKey: String
        let ubidCookieValue: String
        let atCookieKey: String
        let atCookieValue: String

        init(credentials: AmazonPhotosCredentials) {
            sessionID = credentials.sessionID
            ubidCookieKey = credentials.ubidCookieKey
            ubidCookieValue = credentials.ubidCookieValue
            atCookieKey = credentials.atCookieKey
            atCookieValue = credentials.atCookieValue
        }

        var credentials: AmazonPhotosCredentials {
            AmazonPhotosCredentials(
                sessionID: sessionID,
                ubidCookieKey: ubidCookieKey,
                ubidCookieValue: ubidCookieValue,
                atCookieKey: atCookieKey,
                atCookieValue: atCookieValue
            )
        }
    }

    private enum Accounts {
        static let combinedCredentials = "credentials-v1"
        static let legacySessionID = "session-id"
        static let legacyUbidCookieKey = "ubid-cookie-key"
        static let legacyUbidCookieValue = "ubid-cookie-value"
        static let legacyAtCookieKey = "at-cookie-key"
        static let legacyAtCookieValue = "at-cookie-value"

        static let legacy: [String] = [
            legacySessionID,
            legacyUbidCookieKey,
            legacyUbidCookieValue,
            legacyAtCookieKey,
            legacyAtCookieValue,
        ]
    }

    private let service: String

    init(service: String = "com.mhamrah.photosynccompanion.amazonphotos") {
        self.service = service
    }

    func loadCredentials() throws -> AmazonPhotosCredentials? {
        if let combinedData = try readData(account: Accounts.combinedCredentials),
           let decoded = try? JSONDecoder().decode(StoredCredentials.self, from: combinedData) {
            let credentials = decoded.credentials
            return credentials.isComplete ? credentials : nil
        }

        let legacyEntries = try readAllServiceEntries()
        guard
            let sessionID = legacyEntries[Accounts.legacySessionID],
            let ubidCookieKey = legacyEntries[Accounts.legacyUbidCookieKey],
            let ubidCookieValue = legacyEntries[Accounts.legacyUbidCookieValue],
            let atCookieKey = legacyEntries[Accounts.legacyAtCookieKey],
            let atCookieValue = legacyEntries[Accounts.legacyAtCookieValue]
        else { return nil }

        let credentials = AmazonPhotosCredentials(
            sessionID: sessionID,
            ubidCookieKey: ubidCookieKey,
            ubidCookieValue: ubidCookieValue,
            atCookieKey: atCookieKey,
            atCookieValue: atCookieValue
        )
        return credentials.isComplete ? credentials : nil
    }

    func save(credentials: AmazonPhotosCredentials) throws {
        let stored = StoredCredentials(credentials: credentials)
        let data = try JSONEncoder().encode(stored)
        try upsert(data: data, account: Accounts.combinedCredentials)
        try? clearLegacyEntries()
    }

    func clear() throws {
        try delete(account: Accounts.combinedCredentials)
        try clearLegacyEntries()
    }

    private func readData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw AmazonPhotosCredentialStoreError.keychain(status)
        }
    }

    private func readAllServiceEntries() throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            var entries: [String: String] = [:]
            if let items = result as? [[String: Any]] {
                for item in items {
                    guard
                        let account = item[kSecAttrAccount as String] as? String,
                        let data = item[kSecValueData as String] as? Data,
                        let value = String(data: data, encoding: .utf8)
                    else { continue }
                    entries[account] = value
                }
            } else if let item = result as? [String: Any],
                      let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) {
                entries[account] = value
            }
            return entries
        case errSecItemNotFound:
            return [:]
        default:
            throw AmazonPhotosCredentialStoreError.keychain(status)
        }
    }

    private func upsert(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw AmazonPhotosCredentialStoreError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AmazonPhotosCredentialStoreError.keychain(addStatus)
        }
    }

    private func clearLegacyEntries() throws {
        for account in Accounts.legacy {
            try delete(account: account)
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw AmazonPhotosCredentialStoreError.keychain(status)
    }
}
