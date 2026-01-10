import Foundation

enum SharedCaptureStore {
    static let appGroupID = "group.com.digitalhandstand.stuffbucket.app"
    private static let pendingURLsKey = "pendingSharedURLs"

    static func enqueue(url: URL) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var urls = defaults.stringArray(forKey: pendingURLsKey) ?? []
        urls.append(url.absoluteString)
        defaults.set(urls, forKey: pendingURLsKey)
    }

    static func dequeueAll() -> [URL] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        let urls = defaults.stringArray(forKey: pendingURLsKey) ?? []
        defaults.removeObject(forKey: pendingURLsKey)
        return urls.compactMap(URL.init(string:))
    }
}
