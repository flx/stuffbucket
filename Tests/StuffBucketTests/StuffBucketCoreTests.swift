import XCTest
@testable import StuffBucketCore

final class SearchQueryParserTests: XCTestCase {
    func testParsesFiltersAndTerms() {
        let parser = SearchQueryParser()
        let query = parser.parse("tag:\"swift ui\" type:link hello world")

        XCTAssertEqual(query.text, "hello world")
        XCTAssertEqual(query.filters, [
            SearchFilter(key: .tag, value: "swift ui"),
            SearchFilter(key: .type, value: "link")
        ])
    }

    func testKeepsUnknownFiltersAsTerms() {
        let parser = SearchQueryParser()
        let query = parser.parse("unknown:foo title:bar")

        XCTAssertEqual(query.text, "unknown:foo title:bar")
        XCTAssertEqual(query.filters.count, 0)
    }
}

final class SearchQueryBuilderTests: XCTestCase {
    func testBuildsWildcardQueryWithFilters() {
        let query = SearchQuery(
            text: "hello world",
            filters: [SearchFilter(key: .tag, value: "swift ui")],
            sort: .relevance
        )
        let built = SearchQueryBuilder().build(query: query)

        XCTAssertEqual(built, "hello* AND world* AND tags:\"swift ui\"")
    }

    func testPreservesQuotedPhrase() {
        let query = SearchQuery(text: "\"hello world\"", filters: [], sort: .relevance)
        let built = SearchQueryBuilder().build(query: query)

        XCTAssertEqual(built, "\"hello world\"")
    }
}

final class TagCodecTests: XCTestCase {
    func testEncodesAndDecodesTagList() {
        let controller = PersistenceController(inMemory: true)
        let context = controller.viewContext
        let item = Item.create(in: context, type: .note)

        item.setTagList([" swift ", "", "ui"])
        XCTAssertEqual(item.tagList, ["swift", "ui"])

        item.tags = "alpha, beta\ngamma"
        XCTAssertEqual(item.tagList, ["alpha", "beta", "gamma"])
    }
}

final class LinkMetadataParserTests: XCTestCase {
    func testParsesMetadataAndDecodesEntities() {
        let html = """
        <html><head>
        <meta property=\"og:title\" content=\"Hello &amp; World\">
        <meta name=\"author\" content=\"Jane &amp; Doe\">
        <meta property=\"article:published_time\" content=\"2024-01-15T10:30:00Z\">
        </head><body></body></html>
        """
        let url = URL(string: "https://example.com")!

        let metadata = LinkMetadataParser.parse(html: html, fallbackURL: url)

        XCTAssertEqual(metadata.title, "Hello & World")
        XCTAssertEqual(metadata.author, "Jane & Doe")
        let expected = ISO8601DateFormatter().date(from: "2024-01-15T10:30:00Z")
        XCTAssertEqual(metadata.publishedDate, expected)
    }

    func testFallsBackToHostWhenTitleMissing() {
        let html = "<html><head></head><body></body></html>"
        let url = URL(string: "https://example.com/path")!

        let metadata = LinkMetadataParser.parse(html: html, fallbackURL: url)

        XCTAssertEqual(metadata.title, "example.com")
    }
}
