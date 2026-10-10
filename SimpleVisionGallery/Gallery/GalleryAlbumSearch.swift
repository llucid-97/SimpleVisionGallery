import Foundation

/// Stable album ranking: exact, prefix, substring, then a single typo edit.
enum GalleryAlbumSearch {
    private enum Match: Int {
        case exact
        case prefix
        case contains
        case typo
    }

    static func filter(_ albums: [GalleryAlbum], query: String) -> [GalleryAlbum] {
        let normalizedQuery = normalize(String(query.prefix(64)))
        guard !normalizedQuery.isEmpty else { return albums }
        let queryCharacters = Array(normalizedQuery)
        let boundedQuery = normalizedQuery

        return albums.enumerated().compactMap { index, album -> (Int, Int, GalleryAlbum)? in
            let title = normalize(String(album.title.prefix(128)))
            let match: Match?
            if title == boundedQuery {
                match = .exact
            } else if title.hasPrefix(boundedQuery) {
                match = .prefix
            } else if title.contains(boundedQuery) {
                match = .contains
            } else if queryCharacters.count >= 3,
                      matchesFuzzyTitle(queryCharacters, normalizedTitle: title) {
                match = .typo
            } else {
                match = nil
            }
            return match.map { ($0.rawValue, index, album) }
        }
        .sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        .map { $0.2 }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func matchesFuzzyTitle(_ query: [Character], normalizedTitle: String) -> Bool {
        let titleCharacters = Array(normalizedTitle)
        if isOneEditAway(query, titleCharacters) { return true }
        if matchesFuzzyPrefix(query, titleCharacters) { return true }
        return normalizedTitle.split(separator: " ").contains { word in
            let characters = Array(word)
            return isOneEditAway(query, characters) || matchesFuzzyPrefix(query, characters)
        }
    }

    private static func matchesFuzzyPrefix(_ query: [Character], _ title: [Character]) -> Bool {
        let lower = max(1, query.count - 1)
        let upper = min(title.count, query.count + 1)
        guard lower <= upper else { return false }
        for prefixLength in lower...upper where prefixLength <= 128 {
            if isOneEditAway(query, Array(title.prefix(prefixLength))) { return true }
        }
        return false
    }

    /// Linear, bounded check for one insertion, removal, substitution, or adjacent swap.
    private static func isOneEditAway(_ query: [Character], _ title: [Character]) -> Bool {
        let difference = query.count - title.count
        guard abs(difference) <= 1, max(query.count, title.count) <= 128 else { return false }

        if difference == 0 {
            let mismatches = query.indices.filter { query[$0] != title[$0] }
            if mismatches.isEmpty { return false }
            if mismatches.count == 1 { return true }
            guard mismatches.count == 2 else { return false }
            let first = mismatches[0]
            let second = mismatches[1]
            return second == first + 1 && query[first] == title[second] && query[second] == title[first]
        }

        let shorter = difference < 0 ? query : title
        let longer = difference < 0 ? title : query
        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < shorter.count, longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                longIndex += 1
            }
        }
        return true
    }
}
