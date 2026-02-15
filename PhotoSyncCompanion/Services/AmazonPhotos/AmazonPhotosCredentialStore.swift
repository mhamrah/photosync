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
    private let service: String

    init(service: String = "com.mhamrah.photosynccompanion.amazonphotos") {
        self.service = service
    }

    func loadCredentials() throws -> AmazonPhotosCredentials? {
        guard
            let sessionID = try read(account: "session-id"),
            let ubidCookieKey = try read(account: "ubid-cookie-key"),
            let ubidCookieValue = try read(account: "ubid-cookie-value"),
            let atCookieKey = try read(account: "at-cookie-key"),
            let atCookieValue = try read(account: "at-cookie-value")
        else {
            return nil
        }

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
        try upsert(value: credentials.sessionID, account: "session-id")
        try upsert(value: credentials.ubidCookieKey, account: "ubid-cookie-key")
        try upsert(value: credentials.ubidCookieValue, account: "ubid-cookie-value")
        try upsert(value: credentials.atCookieKey, account: "at-cookie-key")
        try upsert(value: credentials.atCookieValue, account: "at-cookie-value")
    }

    func clear() throws {
        try delete(account: "session-id")
        try delete(account: "ubid-cookie-key")
        try delete(account: "ubid-cookie-value")
        try delete(account: "at-cookie-key")
        try delete(account: "at-cookie-value")
    }

    private func read(account: String) throws -> String? {
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
            guard
                let data = result as? Data,
                let value = String(data: data, encoding: .utf8)
            else { return nil }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AmazonPhotosCredentialStoreError.keychain(status)
        }
    }

    private func upsert(value: String, account: String) throws {
        let data = Data(value.utf8)
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
