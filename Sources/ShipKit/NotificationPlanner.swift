import Foundation

/// Decides which PR notifications to post and which to clear after a refresh.
///
/// Notifications are keyed by PR, so each PR has at most one: a newer status replaces the older notification,
/// and a PR that moves to a status not worth notifying about (or leaves the list, or turns quiet) has its old
/// notification cleared instead of leaving stale news in Notification Center.
public enum NotificationPlanner {
    /// Kinds worth interrupting for when a PR moves into them.
    public static let notableKinds: Set<StatusKind> = [
        .reviewRequested, .changesRequested, .ciFailing, .conflicts, .ready,
        .queueFailed, .merged, .deployed, .deployFailed,
    ]

    public struct Candidate: Sendable {
        public let id: String
        public let kind: StatusKind
        /// Whether this PR may notify at all (not in a quiet group, and relevant to the viewer).
        public let eligible: Bool

        public init(id: String, kind: StatusKind, eligible: Bool) {
            self.id = id
            self.kind = kind
            self.eligible = eligible
        }
    }

    public struct Plan: Equatable, Sendable {
        public var post: [String] = []
        public var clear: [String] = []
    }

    public static func plan(previous: [String: StatusKind], current: [Candidate]) -> Plan {
        var plan = Plan()
        for candidate in current {
            let changed = previous[candidate.id] != candidate.kind
            let notable = candidate.eligible && notableKinds.contains(candidate.kind)
            if changed && notable {
                plan.post.append(candidate.id)
            } else if changed || !candidate.eligible {
                plan.clear.append(candidate.id)
            }
        }
        let currentIDs = Set(current.map(\.id))
        plan.clear += previous.keys.filter { !currentIDs.contains($0) }.sorted()
        return plan
    }
}
