import Foundation

public enum ItemType: String, CaseIterable, Codable {
    case note
    case snippet
    case link
    case document
}

public enum ArchiveStatus: String, CaseIterable, Codable {
    case full
    case partial
    case failed
}

public enum ItemSource: String, CaseIterable, Codable {
    case manual
    case shareSheet
    case safariBookmarks
    case `import`
}
