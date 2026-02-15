import Foundation

@MainActor
final class AmazonPhotosSettingsStore: ObservableObject {
    @Published var regionMode: AmazonRegionMode = .auto
    @Published var amazonTLDOverride: String = ""
    @Published var searchFilter: String = AmazonPhotosConfig.default.searchFilter
    @Published var searchSort: String = AmazonPhotosConfig.default.searchSort
    @Published var searchContext: String = AmazonPhotosConfig.default.searchContext
    @Published var lowResThumbnail: Bool = AmazonPhotosConfig.default.lowResThumbnail
    @Published var pageLimit: Int = AmazonPhotosConfig.default.pageLimit
    @Published var maxPages: Int = AmazonPhotosConfig.default.maxPages
    @Published var requestTimeoutSeconds: Double = AmazonPhotosConfig.default.requestTimeoutSeconds
    @Published var maxRetryCount: Int = AmazonPhotosConfig.default.maxRetryCount

    @Published var sessionID: String = ""
    @Published var ubidCookieKey: String = ""
    @Published var ubidCookieValue: String = ""
    @Published var atCookieKey: String = ""
    @Published var atCookieValue: String = ""

    @Published private(set) var authState: AmazonPhotosAuthState = .notConfigured
    @Published private(set) var lastValidationMessage: String = ""
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastValidatedTLD: String?
    @Published private(set) var lastValidatedOwnerID: String?

    private let defaults: UserDefaults
    private let credentialStore: AmazonPhotosCredentialStore

    private enum Keys {
        static let config = "amazonPhotos.config"
        static let lastSuccessfulSyncAt = "amazonPhotos.lastSuccessfulSyncAt"
        static let lastSyncError = "amazonPhotos.lastSyncError"
        static let lastValidatedTLD = "amazonPhotos.lastValidatedTLD"
        static let lastValidatedOwnerID = "amazonPhotos.lastValidatedOwnerID"
    }

    init(defaults: UserDefaults = .standard, credentialStore: AmazonPhotosCredentialStore = AmazonPhotosCredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        load()
    }

    var config: AmazonPhotosConfig {
        .init(
            regionMode: regionMode,
            amazonTLDOverride: amazonTLDOverride,
            searchFilter: searchFilter,
            searchSort: searchSort,
            searchContext: searchContext,
            lowResThumbnail: lowResThumbnail,
            pageLimit: pageLimit,
            maxPages: maxPages,
            requestTimeoutSeconds: requestTimeoutSeconds,
            maxRetryCount: maxRetryCount
        )
    }

    var credentials: AmazonPhotosCredentials {
        .init(
            sessionID: sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
            ubidCookieKey: ubidCookieKey.trimmingCharacters(in: .whitespacesAndNewlines),
            ubidCookieValue: ubidCookieValue.trimmingCharacters(in: .whitespacesAndNewlines),
            atCookieKey: atCookieKey.trimmingCharacters(in: .whitespacesAndNewlines),
            atCookieValue: atCookieValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var hasCompleteCredentials: Bool {
        credentials.isComplete
    }

    var syncConfig: AmazonPhotosConfig {
        var syncConfig = config
        if syncConfig.amazonTLDOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if case .ready(let tld) = authState {
                syncConfig.amazonTLDOverride = tld
            } else if let lastValidatedTLD {
                syncConfig.amazonTLDOverride = lastValidatedTLD
            }
        }
        return syncConfig
    }

    func save() {
        if let configData = try? JSONEncoder().encode(config) {
            defaults.set(configData, forKey: Keys.config)
        }

        if credentials.isComplete {
            do {
                try credentialStore.save(credentials: credentials)
                updateAuthStateIfNeeded()
            } catch {
                authState = .invalid(error.localizedDescription)
            }
        } else {
            do {
                try credentialStore.clear()
                authState = .notConfigured
            } catch {
                authState = .invalid(error.localizedDescription)
            }
        }
    }

    func validateConnection() async {
        guard credentials.isComplete else {
            authState = .notConfigured
            lastValidationMessage = "Enter required cookies before validating."
            return
        }

        save()
        authState = .validating
        lastValidationMessage = ""

        do {
            let client = try AmazonPhotosClient(config: config, credentials: credentials)
            let root = try await client.validateConnection()
            authState = .ready(tld: client.tld)
            lastValidationMessage = "Connected. Root owner: \(root.ownerId ?? "unknown")."
            lastValidatedTLD = client.tld
            defaults.set(client.tld, forKey: Keys.lastValidatedTLD)
            lastValidatedOwnerID = root.ownerId
            defaults.set(root.ownerId, forKey: Keys.lastValidatedOwnerID)
            lastSyncError = nil
            defaults.removeObject(forKey: Keys.lastSyncError)
        } catch {
            authState = .invalid(error.localizedDescription)
            lastValidationMessage = error.localizedDescription
        }
    }

    func recordSyncSuccess(at date: Date = Date()) {
        lastSuccessfulSyncAt = date
        lastSyncError = nil
        defaults.set(date, forKey: Keys.lastSuccessfulSyncAt)
        defaults.removeObject(forKey: Keys.lastSyncError)
    }

    func recordSyncFailure(_ message: String) {
        lastSyncError = message
        defaults.set(message, forKey: Keys.lastSyncError)
    }

    private func load() {
        if
            let configData = defaults.data(forKey: Keys.config),
            let decoded = try? JSONDecoder().decode(AmazonPhotosConfig.self, from: configData)
        {
            regionMode = decoded.regionMode
            amazonTLDOverride = decoded.amazonTLDOverride
            searchFilter = decoded.searchFilter
            searchSort = decoded.searchSort
            searchContext = decoded.searchContext
            lowResThumbnail = decoded.lowResThumbnail
            pageLimit = decoded.pageLimit
            maxPages = decoded.maxPages
            requestTimeoutSeconds = decoded.requestTimeoutSeconds
            maxRetryCount = decoded.maxRetryCount
        }

        if let date = defaults.object(forKey: Keys.lastSuccessfulSyncAt) as? Date {
            lastSuccessfulSyncAt = date
        }
        lastSyncError = defaults.string(forKey: Keys.lastSyncError)
        lastValidatedTLD = defaults.string(forKey: Keys.lastValidatedTLD)
        lastValidatedOwnerID = defaults.string(forKey: Keys.lastValidatedOwnerID)

        if let loadedCredentials = try? credentialStore.loadCredentials() {
            sessionID = loadedCredentials.sessionID
            ubidCookieKey = loadedCredentials.ubidCookieKey
            ubidCookieValue = loadedCredentials.ubidCookieValue
            atCookieKey = loadedCredentials.atCookieKey
            atCookieValue = loadedCredentials.atCookieValue
        }

        updateAuthStateIfNeeded()
    }

    private func updateAuthStateIfNeeded() {
        guard credentials.isComplete else {
            authState = .notConfigured
            return
        }
        do {
            let tld = try AmazonPhotosClient.determineTLD(config: config, credentials: credentials)
            authState = .ready(tld: tld)
            lastValidatedTLD = tld
        } catch {
            authState = .invalid(error.localizedDescription)
        }
    }
}
