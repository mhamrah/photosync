import Foundation

enum AmazonPhotosClientError: LocalizedError {
    case missingCredentials
    case invalidTLD
    case invalidURL
    case invalidRequestBody
    case unauthorized
    case serverError(statusCode: Int, body: String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Amazon credentials are incomplete."
        case .invalidTLD:
            return "Unable to determine Amazon TLD from settings/cookies."
        case .invalidURL:
            return "Invalid Amazon API URL."
        case .invalidRequestBody:
            return "Invalid Amazon API request body."
        case .unauthorized:
            return "Amazon credentials were rejected (401). Refresh cookies and try again."
        case .serverError(let statusCode, let body):
            return "Amazon API failed (\(statusCode)): \(body)"
        case .decoding(let error):
            return "Amazon API response decode failed: \(error.localizedDescription)"
        }
    }
}

actor AmazonPhotosClient {
    let config: AmazonPhotosConfig
    let credentials: AmazonPhotosCredentials
    let tld: String

    private let session: URLSession
    private let decoder = JSONDecoder.amazonPhotosDecoder()

    init(config: AmazonPhotosConfig, credentials: AmazonPhotosCredentials, session: URLSession = .shared) throws {
        guard credentials.isComplete else {
            throw AmazonPhotosClientError.missingCredentials
        }

        self.config = config
        self.credentials = credentials
        self.session = session
        self.tld = try Self.determineTLD(config: config, credentials: credentials)
    }

    func validateConnection() async throws -> AmazonNode {
        let response: AmazonNodesResponse = try await send(
            path: "/nodes",
            extraQueryItems: [URLQueryItem(name: "filters", value: "isRoot:true")]
        )
        guard let rootNode = response.data.first else {
            throw AmazonPhotosClientError.serverError(statusCode: 200, body: "Missing root node.")
        }
        return rootNode
    }

    func fetchSearchPage(offset: Int, limit: Int? = nil) async throws -> AmazonSearchResponse {
        let requestLimit = min(max(limit ?? config.pageLimit, 1), 200)
        return try await send(
            path: "/search",
            extraQueryItems: [
                URLQueryItem(name: "limit", value: "\(requestLimit)"),
                URLQueryItem(name: "offset", value: "\(max(offset, 0))"),
                URLQueryItem(name: "filters", value: config.searchFilter),
                URLQueryItem(name: "lowResThumbnail", value: config.lowResThumbnail ? "true" : "false"),
                URLQueryItem(name: "searchContext", value: config.searchContext),
                URLQueryItem(name: "sort", value: config.searchSort),
            ]
        )
    }

    func fetchThumbnail(nodeID: String, ownerID: String, viewBox: Int = 360) async throws -> Data {
        let encodedNodeID = encodedPathComponent(nodeID)
        guard
            var components = URLComponents(string: "https://thumbnails-photos.amazon.\(tld)/v1/thumbnail/\(encodedNodeID)")
        else {
            throw AmazonPhotosClientError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "ownerId", value: ownerID),
            URLQueryItem(name: "viewBox", value: "\(max(viewBox, 64))"),
        ]

        guard let url = components.url else {
            throw AmazonPhotosClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = config.requestTimeoutSeconds
        applyAuthHeaders(to: &request)
        return try await sendData(request: request)
    }

    func fetchFullSize(nodeID: String, ownerID: String) async throws -> Data {
        let encodedNodeID = encodedPathComponent(nodeID)
        let request = try buildRequest(
            path: "/nodes/\(encodedNodeID)/contentRedirection",
            extraQueryItems: [
                URLQueryItem(name: "querySuffix", value: "?download=true"),
                URLQueryItem(name: "ownerId", value: ownerID),
            ]
        )
        return try await sendData(request: request)
    }

    func uploadFile(data: Data, fileName: String, parentNodeID: String) async throws {
        guard var components = URLComponents(string: cdproxyURLString()) else {
            throw AmazonPhotosClientError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "name", value: fileName),
            URLQueryItem(name: "kind", value: "FILE"),
            URLQueryItem(name: "parentNodeId", value: parentNodeID),
        ]

        guard let url = components.url else {
            throw AmazonPhotosClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(config.requestTimeoutSeconds, 90)
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        _ = try await sendData(request: request)
    }

    func trash(nodeIDs: [String], filters: String = "") async throws {
        let validIDs = nodeIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validIDs.isEmpty else { return }

        for batch in validIDs.chunked(into: 50) {
            let body: [String: Any] = [
                "recurse": "true",
                "op": "add",
                "filters": filters,
                "conflictResolution": "RENAME",
                "value": batch,
                "resourceVersion": "V2",
                "ContentType": "JSON",
            ]
            let request = try buildJSONRequest(path: "/trash", method: "PATCH", body: body)
            _ = try await sendData(request: request)
        }
    }

    func restore(nodeIDs: [String]) async throws {
        let validIDs = nodeIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validIDs.isEmpty else { return }

        for batch in validIDs.chunked(into: 50) {
            let body: [String: Any] = [
                "recurse": "true",
                "op": "remove",
                "conflictResolution": "RENAME",
                "value": batch,
                "resourceVersion": "V2",
                "ContentType": "JSON",
            ]
            let request = try buildJSONRequest(path: "/trash", method: "PATCH", body: body)
            _ = try await sendData(request: request)
        }
    }

    func purge(nodeIDs: [String]) async throws {
        let validIDs = nodeIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validIDs.isEmpty else { return }

        for batch in validIDs.chunked(into: 50) {
            let body: [String: Any] = [
                "recurse": "false",
                "nodeIds": batch,
                "resourceVersion": "V2",
                "ContentType": "JSON",
            ]
            let request = try buildJSONRequest(path: "/bulk/nodes/purge", method: "POST", body: body)
            _ = try await sendData(request: request)
        }
    }

    func delete(nodeIDs: [String]) async throws {
        try await purge(nodeIDs: nodeIDs)
    }

    private func send<T: Decodable>(path: String, extraQueryItems: [URLQueryItem]) async throws -> T {
        let request = try buildRequest(path: path, extraQueryItems: extraQueryItems)
        let data = try await sendData(request: request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AmazonPhotosClientError.decoding(error)
        }
    }

    private func sendData(request: URLRequest) async throws -> Data {
        let maxRetries = max(config.maxRetryCount, 0)

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AmazonPhotosClientError.serverError(statusCode: -1, body: "No HTTPURLResponse.")
                }

                switch httpResponse.statusCode {
                case 200 ..< 300:
                    return data
                case 401:
                    throw AmazonPhotosClientError.unauthorized
                case 429, 500 ... 599:
                    if attempt >= maxRetries {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw AmazonPhotosClientError.serverError(statusCode: httpResponse.statusCode, body: body)
                    }
                    try await Task.sleep(nanoseconds: backoffNanoseconds(forAttempt: attempt))
                    attempt += 1
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw AmazonPhotosClientError.serverError(statusCode: httpResponse.statusCode, body: body)
                }
            } catch {
                if let clientError = error as? AmazonPhotosClientError {
                    throw clientError
                }
                if attempt >= maxRetries {
                    throw AmazonPhotosClientError.serverError(statusCode: -1, body: error.localizedDescription)
                }
                try await Task.sleep(nanoseconds: backoffNanoseconds(forAttempt: attempt))
                attempt += 1
            }
        }
    }

    private func buildRequest(path: String, extraQueryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(string: "https://www.amazon.\(tld)/drive/v1\(path)") else {
            throw AmazonPhotosClientError.invalidURL
        }

        let baseQueryItems = [
            URLQueryItem(name: "asset", value: "ALL"),
            URLQueryItem(name: "tempLink", value: "false"),
            URLQueryItem(name: "resourceVersion", value: "V2"),
            URLQueryItem(name: "ContentType", value: "JSON"),
        ]
        components.queryItems = baseQueryItems + extraQueryItems

        guard let url = components.url else {
            throw AmazonPhotosClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = config.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthHeaders(to: &request)
        return request
    }

    private func buildJSONRequest(path: String, method: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: "https://www.amazon.\(tld)/drive/v1\(path)") else {
            throw AmazonPhotosClientError.invalidURL
        }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw AmazonPhotosClientError.invalidRequestBody
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = max(config.requestTimeoutSeconds, 30)
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(to: &request)
        return request
    }

    private func backoffNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let seconds = min(pow(2.0, Double(attempt)) * 0.5, 20)
        return UInt64(seconds * 1_000_000_000)
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        request.setValue("PhotoSyncCompanion/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(credentials.sessionID, forHTTPHeaderField: "x-amzn-sessionid")
        request.setValue(credentials.cookieHeaderValue, forHTTPHeaderField: "Cookie")
    }

    private func cdproxyURLString() -> String {
        if tld == "com" || tld == "ca" {
            return "https://content-na.drive.amazonaws.com/cdproxy/nodes"
        }
        return "https://content-eu.drive.amazonaws.com/cdproxy/nodes"
    }

    private func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    static func determineTLD(config: AmazonPhotosConfig, credentials: AmazonPhotosCredentials) throws -> String {
        let override = config.amazonTLDOverride.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !override.isEmpty {
            return override
        }

        let normalizedAtKey = normalizeCookieKey(credentials.atCookieKey)
        let normalizedUbidKey = normalizeCookieKey(credentials.ubidCookieKey)

        switch config.regionMode {
        case .us:
            return "com"
        case .ca:
            return "ca"
        case .eu:
            if let tld = extractACBTLD(from: normalizedAtKey) ?? extractACBTLD(from: normalizedUbidKey) {
                return tld
            }
            throw AmazonPhotosClientError.invalidTLD
        case .auto:
            if normalizedAtKey.hasSuffix("_main") || normalizedUbidKey.hasSuffix("_main") {
                return "com"
            }
            if let tld = extractACBTLD(from: normalizedAtKey) ?? extractACBTLD(from: normalizedUbidKey) {
                return tld
            }
            return "com"
        }
    }

    private static func extractACBTLD(from cookieKey: String) -> String? {
        if cookieKey.hasPrefix("at_acb") {
            let suffix = cookieKey.dropFirst("at_acb".count).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            return suffix.isEmpty ? nil : suffix
        }
        if cookieKey.hasPrefix("ubid_acb") {
            let suffix = cookieKey.dropFirst("ubid_acb".count).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }

    private static func normalizeCookieKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count / size) + 1)
        var index = 0
        while index < count {
            let nextIndex = Swift.min(index + size, count)
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return chunks
    }
}
