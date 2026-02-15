import Foundation

enum AmazonRegionMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case us
    case ca
    case eu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .us: return "United States"
        case .ca: return "Canada"
        case .eu: return "Europe"
        }
    }
}

struct AmazonPhotosConfig: Codable, Equatable {
    var regionMode: AmazonRegionMode = .auto
    var amazonTLDOverride: String = ""
    var searchFilter: String = "type:(PHOTOS OR VIDEOS)"
    var searchSort: String = "['createdDate DESC']"
    var searchContext: String = "customer"
    var lowResThumbnail: Bool = true
    var pageLimit: Int = 200
    var maxPages: Int = 0
    var requestTimeoutSeconds: Double = 30
    var maxRetryCount: Int = 6

    static let `default` = AmazonPhotosConfig()
}

struct AmazonPhotosCredentials: Equatable {
    var sessionID: String
    var ubidCookieKey: String
    var ubidCookieValue: String
    var atCookieKey: String
    var atCookieValue: String

    var isComplete: Bool {
        !sessionID.trimmed.isEmpty &&
            !ubidCookieKey.trimmed.isEmpty &&
            !ubidCookieValue.trimmed.isEmpty &&
            !atCookieKey.trimmed.isEmpty &&
            !atCookieValue.trimmed.isEmpty
    }

    var cookieHeaderValue: String {
        [
            "session-id=\(sessionID)",
            "\(ubidCookieKey)=\(ubidCookieValue)",
            "\(atCookieKey)=\(atCookieValue)",
        ].joined(separator: "; ")
    }
}

enum AmazonPhotosAuthState: Equatable {
    case notConfigured
    case validating
    case ready(tld: String)
    case invalid(String)

    var title: String {
        switch self {
        case .notConfigured:
            return "Not Configured"
        case .validating:
            return "Validating Connection"
        case .ready(let tld):
            return "Connected (amazon.\(tld))"
        case .invalid:
            return "Connection Failed"
        }
    }
}

struct AmazonNodesResponse: Decodable {
    let data: [AmazonNode]
    let count: Int?
}

struct AmazonSearchResponse: Decodable {
    let count: Int
    let data: [AmazonNode]
}

struct AmazonNode: Codable, Hashable {
    struct ContentProperties: Codable, Hashable {
        let md5: String?
        let size: Int64?
        let contentType: String?
        let ext: String?
        let contentDate: Date?

        enum CodingKeys: String, CodingKey {
            case md5
            case size
            case contentType
            case ext = "extension"
            case contentDate
        }
    }

    struct ImageMetadata: Codable, Hashable {
        let width: Int32?
        let height: Int32?
    }

    struct VideoMetadata: Codable, Hashable {
        let width: Int32?
        let height: Int32?
        let duration: Double?
    }

    let id: String
    let name: String?
    let parents: [String]?
    let ownerId: String?
    let createdDate: Date?
    let modifiedDate: Date?
    let contentProperties: ContentProperties?
    let image: ImageMetadata?
    let video: VideoMetadata?

    var resolvedWidth: Int32 {
        image?.width ?? video?.width ?? 0
    }

    var resolvedHeight: Int32 {
        image?.height ?? video?.height ?? 0
    }

    var resolvedDuration: Double {
        video?.duration ?? 0
    }
}

extension JSONDecoder {
    static func amazonPhotosDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = DateFormatter.amazonPhotosMilliseconds.date(from: value) {
                return date
            }
            if let date = ISO8601DateFormatter.amazonPhotosNoMilliseconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Amazon date format: \(value)"
            )
        }
        return decoder
    }
}

extension JSONEncoder {
    static func amazonPhotosEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension DateFormatter {
    static let amazonPhotosMilliseconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
}

private extension ISO8601DateFormatter {
    static let amazonPhotosNoMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
