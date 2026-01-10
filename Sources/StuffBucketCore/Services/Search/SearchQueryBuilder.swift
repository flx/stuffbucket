import Foundation

public struct SearchQueryParser {
    public init() {}

    public func parse(_ input: String, sort: SearchSort = .relevance) -> SearchQuery {
        let tokens = tokenize(input)
        var filters: [SearchFilter] = []
        var terms: [String] = []

        for token in tokens {
            if let filter = parseFilter(token) {
                filters.append(filter)
            } else {
                terms.append(token)
            }
        }

        let text = terms.joined(separator: " ")
        return SearchQuery(text: text, filters: filters, sort: sort)
    }

    private func parseFilter(_ token: String) -> SearchFilter? {
        guard let colonIndex = token.firstIndex(of: ":"), colonIndex != token.startIndex else {
            return nil
        }

        let key = token[..<colonIndex].lowercased()
        let valueStart = token.index(after: colonIndex)
        let rawValue = String(token[valueStart...])
        let trimmedValue = trimQuotes(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        guard let filterKey = SearchFilterKey(rawValue: key) else {
            return nil
        }

        return SearchFilter(key: filterKey, value: trimmedValue)
    }

    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in input {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }

            if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func trimQuotes(_ value: String) -> String {
        var result = value
        if result.hasPrefix("\"") {
            result.removeFirst()
        }
        if result.hasSuffix("\"") {
            result.removeLast()
        }
        return result
    }
}

public struct SearchQueryBuilder {
    public init() {}

    public func build(query: SearchQuery) -> String {
        var clauses: [String] = []

        if let termClause = buildTermClause(from: query.text), !termClause.isEmpty {
            clauses.append(termClause)
        }

        for filter in query.filters {
            let column = columnName(for: filter.key)
            let valueClause = buildValueClause(for: filter.value)
            if !valueClause.isEmpty {
                clauses.append("\(column):\(valueClause)")
            }
        }

        return clauses.joined(separator: " AND ")
    }

    private func buildTermClause(from text: String) -> String? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        let terms = tokens.map { term in
            buildValueClause(for: term)
        }
        return terms.joined(separator: " AND ")
    }

    private func buildValueClause(for term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            return trimmed
        }

        if trimmed.contains(where: { $0.isWhitespace }) {
            return "\"\(trimmed)\""
        }

        if trimmed.contains("*") {
            return trimmed
        }

        return "\(trimmed)*"
    }

    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in input {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }

            if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func columnName(for key: SearchFilterKey) -> String {
        switch key {
        case .type:
            return "type"
        case .tag:
            return "tags"
        case .collection:
            return "collection"
        case .source:
            return "source"
        }
    }
}
