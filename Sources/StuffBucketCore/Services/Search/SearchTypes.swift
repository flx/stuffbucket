import Foundation

public enum SearchSort: String, CaseIterable, Codable {
    case relevance
    case recency
}

public enum SearchFilterKey: String, CaseIterable, Codable {
    case type
    case tag
    case collection
    case source
    case date
}

public struct SearchFilter: Hashable, Codable {
    public let key: SearchFilterKey
    public let value: String

    public init(key: SearchFilterKey, value: String) {
        self.key = key
        self.value = value
    }
}

public struct SearchQuery: Hashable, Codable {
    public let text: String
    public let filters: [SearchFilter]
    public let sort: SearchSort

    public init(text: String, filters: [SearchFilter] = [], sort: SearchSort = .relevance) {
        self.text = text
        self.filters = filters
        self.sort = sort
    }
}

public struct SearchResult: Hashable, Codable {
    public let itemID: UUID
    public let title: String
    public let snippet: String?

    public init(itemID: UUID, title: String, snippet: String? = nil) {
        self.itemID = itemID
        self.title = title
        self.snippet = snippet
    }
}

extension SearchResult: Identifiable {
    public var id: UUID { itemID }
}

// MARK: - Date Filter

public enum DateFilterType {
    case year(Int)                          // date:2025
    case after(Date)                        // date:>2024 or date:>1/15/2025
    case before(Date)                       // date:<2025 or date:<1/15/2025
    case range(start: Date, end: Date)      // date:11/30/2025-1/23/2026
}

public struct DateFilter {
    public let type: DateFilterType

    public init?(from value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Check for range: date:11/30/2025-1/23/2026
        if trimmed.contains("-"), !trimmed.hasPrefix(">"), !trimmed.hasPrefix("<") {
            let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let startResult = Self.parseDateWithGranularity(parts[0]),
               let endResult = Self.parseDateWithGranularity(parts[1]) {
                let start = startResult.date
                var end = endResult.date
                // Adjust end date based on granularity
                if endResult.isMonthOnly {
                    // End of month
                    end = Calendar.current.date(byAdding: .month, value: 1, to: end) ?? end
                } else {
                    // End of day
                    end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
                }
                self.type = .range(start: start, end: end)
                return
            }
            // Could be a single date with dashes (unlikely given MM/DD/YYYY format)
        }

        // Check for comparison: date:>2024 or date:<2025 or date:>5/2025
        if trimmed.hasPrefix(">") {
            let dateStr = String(trimmed.dropFirst())
            if let date = Self.parseDate(dateStr) {
                self.type = .after(date)
                return
            } else if let year = Int(dateStr), year > 1900, year < 3000 {
                // Start of year
                let components = DateComponents(year: year, month: 1, day: 1)
                if let date = Calendar.current.date(from: components) {
                    self.type = .after(date)
                    return
                }
            }
            return nil
        }

        if trimmed.hasPrefix("<") {
            let dateStr = String(trimmed.dropFirst())
            if let date = Self.parseDate(dateStr) {
                self.type = .before(date)
                return
            } else if let year = Int(dateStr), year > 1900, year < 3000 {
                // Start of year
                let components = DateComponents(year: year, month: 1, day: 1)
                if let date = Calendar.current.date(from: components) {
                    self.type = .before(date)
                    return
                }
            }
            return nil
        }

        // Check for year only: date:2025
        if let year = Int(trimmed), year > 1900, year < 3000 {
            self.type = .year(year)
            return
        }

        // Try parsing as a single date with granularity detection
        if let result = Self.parseDateWithGranularity(trimmed) {
            if result.isMonthOnly {
                // Month only: match entire month
                let endOfMonth = Calendar.current.date(byAdding: .month, value: 1, to: result.date) ?? result.date
                self.type = .range(start: result.date, end: endOfMonth)
            } else {
                // Single day
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: result.date) ?? result.date
                self.type = .range(start: result.date, end: endOfDay)
            }
            return
        }

        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Try MM/DD/YYYY
        let slashFormatter = DateFormatter()
        slashFormatter.dateFormat = "M/d/yyyy"
        if let date = slashFormatter.date(from: trimmed) {
            return date
        }

        // Try M/YYYY (month/year)
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "M/yyyy"
        if let date = monthYearFormatter.date(from: trimmed) {
            return date
        }

        // Try YYYY-MM-DD
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        // Try MM-DD-YYYY
        let dashFormatter = DateFormatter()
        dashFormatter.dateFormat = "M-d-yyyy"
        if let date = dashFormatter.date(from: trimmed) {
            return date
        }

        return nil
    }

    /// Parses a date string and returns both the date and whether it's a month-only format
    private static func parseDateWithGranularity(_ string: String) -> (date: Date, isMonthOnly: Bool)? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Try M/YYYY (month/year) first to detect month-only
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "M/yyyy"
        if let date = monthYearFormatter.date(from: trimmed) {
            return (date, true)
        }

        // Try other formats (not month-only)
        if let date = parseDate(trimmed) {
            return (date, false)
        }

        return nil
    }

    public func matches(date: Date?) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current

        switch type {
        case .year(let year):
            return calendar.component(.year, from: date) == year

        case .after(let afterDate):
            return date >= afterDate

        case .before(let beforeDate):
            return date < beforeDate

        case .range(let start, let end):
            return date >= start && date < end
        }
    }
}
