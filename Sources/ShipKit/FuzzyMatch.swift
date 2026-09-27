import Foundation

/// Subsequence fuzzy matching, in the style of editor "quick open" pickers.
public enum FuzzyMatch {
    public struct Result: Sendable {
        public let score: Int
        /// Offsets (in `Character`s) of the matched characters in the candidate, for highlighting.
        public let positions: [Int]
    }

    /// Returns nil unless every character of `query` appears in `candidate` in order (case-insensitive).
    /// Higher scores are better: prefix, word-start, and consecutive matches are rewarded; gaps cost a little.
    public static func match(_ query: String, in candidate: String) -> Result? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        let original = Array(candidate)
        let c = original.map { Character($0.lowercased()) }

        var positions: [Int] = []
        var score = 0
        var qi = 0
        var previous = -1
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var points = 1
            if ci == 0 {
                points += 8
            } else if isBoundary(original[ci - 1], original[ci]) {
                points += 6
            }
            if previous == ci - 1 {
                points += 5
            } else if previous >= 0 {
                points -= min(ci - previous - 1, 3)
            }
            score += points
            positions.append(ci)
            previous = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates and exact matches when scores tie.
        score -= c.count / 8
        if c == q { score += 20 }
        return Result(score: score, positions: positions)
    }

    /// Candidates that match, best first. Ties keep the input order.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [(item: T, result: Result)] {
        items.enumerated()
            .compactMap { index, item in match(query, in: key(item)).map { (index, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }

    private static func isBoundary(_ before: Character, _ current: Character) -> Bool {
        if " -_/:.".contains(before) { return true }
        return before.isLowercase && current.isUppercase
    }
}
