import Foundation
import CoreData

public final class LinkArchiver {
    public static let shared = LinkArchiver()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func archive(itemID: UUID, context: NSManagedObjectContext) {
        context.perform { [weak self] in
            guard let self else { return }
            guard let urlString = self.fetchLinkURL(itemID: itemID, context: context),
                  let url = URL(string: urlString) else {
                return
            }
            let request = self.buildRequest(url: url)
            let task = self.session.dataTask(with: request) { data, _, error in
                if let data {
                    self.handleArchiveSuccess(data: data, url: url, itemID: itemID, context: context)
                } else if let error {
                    self.handleArchiveFailure(error: error, itemID: itemID, context: context)
                }
            }
            task.resume()
        }
    }

    private func fetchLinkURL(itemID: UUID, context: NSManagedObjectContext) -> String? {
        let request = NSFetchRequest<Item>(entityName: "Item")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
        guard let item = try? context.fetch(request).first else {
            return nil
        }
        return item.linkURL
    }

    private func buildRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) StuffBucket/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    private func handleArchiveSuccess(data: Data, url: URL, itemID: UUID, context: NSManagedObjectContext) {
        let htmlString = String(decoding: data, as: UTF8.self)
        let metadata = LinkMetadataParser.parse(html: htmlString, fallbackURL: url)
        let archiveStatus: ArchiveStatus
        let relativePath: String?
        do {
            relativePath = try LinkStorage.writeHTML(data: data, itemID: itemID)
            archiveStatus = .full
        } catch {
            relativePath = nil
            archiveStatus = .failed
        }
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            guard let item = try? context.fetch(request).first else { return }
            if let title = metadata.title {
                item.linkTitle = title
                item.title = title
            }
            item.linkAuthor = metadata.author
            item.linkPublishedDate = metadata.publishedDate
            item.htmlRelativePath = relativePath
            item.archiveStatus = archiveStatus.rawValue
            item.updatedAt = Date()
            if context.hasChanges {
                try? context.save()
            }
        }
    }

    private func handleArchiveFailure(error: Error, itemID: UUID, context: NSManagedObjectContext) {
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            guard let item = try? context.fetch(request).first else { return }
            item.archiveStatus = ArchiveStatus.failed.rawValue
            item.updatedAt = Date()
            if context.hasChanges {
                try? context.save()
            }
        }
    }
}

