import AppKit
import Photos

@MainActor
final class PhotoLibraryAuthorizationController: ObservableObject {
    enum AuthorizationRequestTrigger {
        case automatic
        case userInitiated
    }

    enum AuthorizationState: Equatable {
        case notDetermined
        case requesting
        case authorized
        case limited
        case denied
        case restricted
        case error(String)

        init(status: PHAuthorizationStatus) {
            switch status {
            case .notDetermined:
                self = .notDetermined
            case .authorized:
                self = .authorized
            case .limited:
                self = .limited
            case .denied:
                self = .denied
            case .restricted:
                self = .restricted
            @unknown default:
                self = .error("Unknown authorization status: \(status.rawValue)")
            }
        }

        var blocksInteraction: Bool {
            switch self {
            case .authorized, .limited:
                return false
            case .notDetermined, .requesting, .denied, .restricted, .error:
                return true
            }
        }

        var title: String {
            switch self {
            case .notDetermined:
                return "Photo Library Access Needed"
            case .requesting:
                return "Requesting Photo Library Access"
            case .authorized:
                return "Access Granted"
            case .limited:
                return "Limited Access"
            case .denied:
                return "Photo Library Access Denied"
            case .restricted:
                return "Photo Library Access Restricted"
            case .error:
                return "Photo Library Error"
            }
        }

        var message: String {
            switch self {
            case .notDetermined:
                return "PhotoSync Companion needs permission to read your Apple Photos library so it can compare with Amazon Photos. Select Allow Access to continue."
            case .requesting:
                return "PhotoSync Companion needs permission to read your Apple Photos library so it can compare with Amazon Photos."
            case .authorized:
                return "Photo library access is available."
            case .limited:
                return "Only a limited set of photos is available. You can grant full access from System Settings to ensure comparisons are comprehensive."
            case .denied:
                return "Access was denied. You can grant permission from System Settings > Privacy & Security > Photos."
            case .restricted:
                return "Access is restricted and cannot be changed for this account."
            case .error(let message):
                return message
            }
        }

        var shouldShowOpenSettings: Bool {
            switch self {
            case .denied:
                return true
            case .notDetermined, .requesting, .authorized, .limited, .restricted, .error:
                return false
            }
        }
    }

    private static let hasAttemptedAutomaticPromptKey = "PhotoSyncCompanion.hasAttemptedPhotoAccessPrompt"

    @Published private(set) var state: AuthorizationState
    private var isRequestInFlight = false
    private let userDefaults: UserDefaults

    init(initialStatus: PHAuthorizationStatus? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let status = initialStatus ?? PHPhotoLibrary.authorizationStatus(for: .readWrite)
        state = AuthorizationState(status: status)
    }

    func requestAuthorizationIfNeeded(trigger: AuthorizationRequestTrigger = .automatic) async {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard currentStatus == .notDetermined else {
            state = AuthorizationState(status: currentStatus)
            return
        }

        if isRequestInFlight {
            return
        }

        if trigger == .automatic,
           userDefaults.bool(forKey: Self.hasAttemptedAutomaticPromptKey) {
            state = .notDetermined
            return
        }

        if trigger == .automatic {
            userDefaults.set(true, forKey: Self.hasAttemptedAutomaticPromptKey)
        }

        state = .requesting
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        let newStatus = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }

        state = AuthorizationState(status: newStatus)
    }

    func refreshAuthorizationStatus() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        state = AuthorizationState(status: status)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension PhotoLibraryAuthorizationController {
    static var previewAuthorized: PhotoLibraryAuthorizationController {
        PhotoLibraryAuthorizationController(initialStatus: .authorized)
    }

    static var previewDenied: PhotoLibraryAuthorizationController {
        PhotoLibraryAuthorizationController(initialStatus: .denied)
    }
}
