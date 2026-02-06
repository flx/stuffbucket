import Foundation

public enum SyncPolicy {
    private static let maxFileSizeMBKey = "com.digitalhandstand.stuffbucket.sync.maxFileSizeMB"

    public static let defaultMaxFileSizeMB: Int = 512
    public static let minimumMaxFileSizeMB: Int = 50
    public static let maximumMaxFileSizeMB: Int = 4096

    public static var maxFileSizeMB: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: maxFileSizeMBKey)
            if stored == 0 {
                return defaultMaxFileSizeMB
            }
            return clampMB(stored)
        }
        set {
            UserDefaults.standard.set(clampMB(newValue), forKey: maxFileSizeMBKey)
        }
    }

    public static var maxFileSizeBytes: Int64 {
        Int64(maxFileSizeMB) * 1_048_576
    }

    private static func clampMB(_ value: Int) -> Int {
        min(max(value, minimumMaxFileSizeMB), maximumMaxFileSizeMB)
    }
}

public enum SyncError: LocalizedError {
    case fileTooLarge(fileName: String, actualBytes: Int64, limitBytes: Int64)
    case syncBundleCreationFailed(fileName: String)
    case materializationFolderNotSelected
    case materializationCancelled
    case documentUnavailable

    public var errorDescription: String? {
        switch self {
        case let .fileTooLarge(fileName, actualBytes, limitBytes):
            return "\(fileName) is \(format(bytes: actualBytes)), which exceeds the sync limit of \(format(bytes: limitBytes))."
        case let .syncBundleCreationFailed(fileName):
            return "Could not prepare \(fileName) for CloudKit sync."
        case .materializationFolderNotSelected:
            return "Choose a destination folder before using Show in Finder."
        case .materializationCancelled:
            return "Folder selection was cancelled."
        case .documentUnavailable:
            return "The document is not available on this device yet."
        }
    }

    private func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
