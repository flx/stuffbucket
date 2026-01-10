import CoreData
import Foundation

public extension SearchIndexMetadata {
    static func create(in context: NSManagedObjectContext, version: Int64 = 1) -> SearchIndexMetadata {
        let metadata = SearchIndexMetadata(context: context)
        metadata.id = UUID()
        metadata.version = version
        return metadata
    }
}
