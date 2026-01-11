import Foundation

enum SharedCaptureNotifier {
    static let notificationName = "com.digitalhandstand.stuffbucket.sharedcapture" as CFString
    static let notificationNameValue = CFNotificationName(notificationName)

    static func post() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            notificationNameValue,
            nil,
            nil,
            true
        )
    }
}

final class SharedCaptureObserver {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<SharedCaptureObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    instance.handler()
                }
            },
            SharedCaptureNotifier.notificationName,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            SharedCaptureNotifier.notificationNameValue,
            nil
        )
    }
}

struct SharedCaptureItem: Codable, Hashable {
    let url: URL
    let tagsText: String?
}

enum SharedCaptureStore {
    static let appGroupID = "group.com.digitalhandstand.stuffbucket.app"
    private static let pendingItemsKey = "pendingSharedItems"
    private static let pendingURLsKey = "pendingSharedURLs"

    static func enqueue(url: URL, tagsText: String? = nil) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var items = loadItems(from: defaults)
        let trimmedTags = tagsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTags = trimmedTags?.isEmpty == false ? trimmedTags : nil
        items.append(SharedCaptureItem(url: url, tagsText: storedTags))
        saveItems(items, to: defaults)
    }

    static func dequeueAll() -> [SharedCaptureItem] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        CFPreferencesAppSynchronize(appGroupID as CFString)
        defaults.synchronize()
        var items = loadItems(from: defaults)
        let legacyURLs = defaults.stringArray(forKey: pendingURLsKey) ?? []
        for urlString in legacyURLs {
            if let url = URL(string: urlString) {
                items.append(SharedCaptureItem(url: url, tagsText: nil))
            }
        }
        defaults.removeObject(forKey: pendingURLsKey)
        defaults.removeObject(forKey: pendingItemsKey)
        return items
    }

    private static func loadItems(from defaults: UserDefaults) -> [SharedCaptureItem] {
        guard let data = defaults.data(forKey: pendingItemsKey) else { return [] }
        return (try? JSONDecoder().decode([SharedCaptureItem].self, from: data)) ?? []
    }

    private static func saveItems(_ items: [SharedCaptureItem], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: pendingItemsKey)
        defaults.synchronize()
        SharedCaptureNotifier.post()
    }
}
