import Foundation

/// A named, collapsible bucket of pull requests. A PR joins the first group with a filter that matches it,
/// and then shows up only in that group's section.
public struct PRGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Filters in `PRFilter` syntax. A PR matches the group if any of them match.
    public var rules: [String]
    /// Quiet groups don't count toward the menu bar badge and don't send notifications.
    public var quiet: Bool

    public init(id: UUID = UUID(), name: String, rules: [String] = [], quiet: Bool = true) {
        self.id = id
        self.name = name
        self.rules = rules
        self.quiet = quiet
    }

    public var filters: [PRFilter] { rules.map(PRFilter.init) }

    public func matches(_ pr: PullRequest) -> Bool {
        filters.contains { $0.matches(pr) }
    }

    /// The first group that claims `pr`, if any.
    public static func group(for pr: PullRequest, in groups: [PRGroup]) -> PRGroup? {
        groups.first { $0.matches(pr) }
    }
}

/// One-click filters offered for a PR (right-click → Group), each with a suggested group name.
public struct FilterSuggestion: Hashable, Sendable {
    public let title: String
    public let rule: String
    public let groupName: String

    public static func suggestions(for pr: PullRequest) -> [FilterSuggestion] {
        var result = [
            FilterSuggestion(title: "PRs in \(pr.repo)", rule: "repo:\(pr.repo)", groupName: pr.repo),
            FilterSuggestion(title: "PRs by @\(pr.author)", rule: "author:\(quoted(pr.author))", groupName: "@\(pr.author)"),
        ]
        result += pr.labels.map {
            FilterSuggestion(title: "PRs labeled “\($0.name)”", rule: "label:\(quoted($0.name))", groupName: $0.name)
        }
        result.append(FilterSuggestion(
            title: "This PR",
            rule: "repo:\(pr.repo) title:\(quoted(pr.title))",
            groupName: "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)"
        ))
        return result
    }

    static func quoted(_ s: String) -> String {
        s.contains(where: \.isWhitespace) ? "\"\(s)\"" : s
    }
}
