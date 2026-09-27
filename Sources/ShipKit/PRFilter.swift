import Foundation

/// A filter over pull requests, written like a GitHub search:
///
///     repo:acme/optional-*                      any repo matching the glob
///     author:dependabot* label:dependencies     all terms must match
///     org:acme                                  repo owner
///     "bump version"                            bare words / quoted phrases match the title
///     title:release* -label:urgent              `-` negates a term
///     is:draft  is:merged  is:review-requested  PR state / your relation to it
///
/// Values are case-insensitive globs (`*`, `?`). Bare title words match anywhere in the title.
public struct PRFilter: Hashable, Sendable {
    public enum Field: String, Sendable, CaseIterable {
        case repo, org, author, label, title, `is`
    }

    public struct Term: Hashable, Sendable {
        public let field: Field
        public let pattern: String
        public let negated: Bool
    }

    public let source: String
    public let terms: [Term]
    /// Problems found while parsing, e.g. unknown qualifiers. A filter with errors never matches.
    public let errors: [String]

    public init(_ source: String) {
        self.source = source
        var terms: [Term] = []
        var errors: [String] = []
        for token in Self.tokenize(source) {
            var token = token
            let negated = token.hasPrefix("-") && token.count > 1
            if negated { token.removeFirst() }
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                guard let field = Field(rawValue: key == "owner" || key == "user" ? "org" : key) else {
                    errors.append("Unknown qualifier “\(key):”")
                    continue
                }
                guard !value.isEmpty else {
                    errors.append("“\(key):” needs a value")
                    continue
                }
                if field == .is, !Self.isValues.contains(value.lowercased()) {
                    errors.append("Unknown “is:\(value)”")
                    continue
                }
                terms.append(Term(field: field, pattern: value, negated: negated))
            } else {
                // Bare words match anywhere in the title.
                terms.append(Term(field: .title, pattern: "*\(token)*", negated: negated))
            }
        }
        self.terms = terms
        self.errors = errors
    }

    public var isValid: Bool { errors.isEmpty && !terms.isEmpty }

    public func matches(_ pr: PullRequest) -> Bool {
        isValid && terms.allSatisfy { $0.matches(pr) != $0.negated }
    }

    static let isValues: Set<String> = ["draft", "open", "merged", "authored", "review-requested", "reviewed"]

    /// Splits on whitespace, keeping "quoted phrases" (including `label:"needs qa"`) together.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for c in s {
            if c == "\"" {
                quoted.toggle()
            } else if c.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

extension PRFilter.Term {
    func matches(_ pr: PullRequest) -> Bool {
        switch field {
        case .repo:
            // Allow `repo:rocket` as shorthand for any owner.
            glob(pattern, pr.repo) || (!pattern.contains("/") && glob(pattern, pr.repo.split(separator: "/").last.map(String.init) ?? ""))
        case .org:
            glob(pattern, pr.repo.split(separator: "/").first.map(String.init) ?? "")
        case .author:
            glob(pattern, pr.author) || glob(pattern, pr.author.replacingOccurrences(of: "[bot]", with: ""))
        case .label:
            pr.labels.contains { glob(pattern, $0.name) }
        case .title:
            glob(pattern, pr.title)
        case .is:
            switch pattern.lowercased() {
            case "draft": pr.isDraft
            case "open": pr.isOpen
            case "merged": pr.isMerged
            case "authored": pr.relations.contains(.authored)
            case "review-requested": pr.relations.contains(.reviewRequested)
            case "reviewed": pr.relations.contains(.reviewed)
            default: false
            }
        }
    }
}

/// Case-insensitive glob supporting `*` and `?`.
func glob(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.lowercased()), t = Array(text.lowercased())
    var pi = 0, ti = 0, star = -1, mark = 0
    while ti < t.count {
        if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
            pi += 1; ti += 1
        } else if pi < p.count, p[pi] == "*" {
            star = pi; mark = ti; pi += 1
        } else if star >= 0 {
            pi = star + 1; mark += 1; ti = mark
        } else {
            return false
        }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}
