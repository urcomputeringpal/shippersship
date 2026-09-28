import Foundation

/// How the signed-in user is connected to a pull request.
public enum Relation: String, Hashable, Sendable, CaseIterable {
    case authored
    case reviewRequested
    case reviewed
    case merged
}

public enum CheckItemState: Hashable, Sendable {
    case success, failure, pending, neutral
}

public struct CheckItem: Hashable, Sendable {
    public let name: String
    public let state: CheckItemState
    public let url: URL?

    public init(name: String, state: CheckItemState, url: URL?) {
        self.name = name
        self.state = state
        self.url = url
    }
}

public struct ChecksSummary: Hashable, Sendable {
    /// GitHub's rollup state: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or nil when no checks exist.
    public let rollup: String?
    public let items: [CheckItem]

    public init(rollup: String?, items: [CheckItem]) {
        self.rollup = rollup
        self.items = items
    }

    public var failed: [CheckItem] { items.filter { $0.state == .failure } }
    public var pending: [CheckItem] { items.filter { $0.state == .pending } }
    public var passed: [CheckItem] { items.filter { $0.state == .success || $0.state == .neutral } }
}

extension URL {
    /// Only http(s) links are safe to open. Check and deployment URLs are set by third parties (CI systems,
    /// integrations, other people's workflows), and `file:`, `smb:`, or custom-scheme URLs could read local files,
    /// leak credentials to a remote SMB server, or trigger other apps' URL handlers.
    public var isWebURL: Bool {
        guard let scheme = scheme?.lowercased(), host != nil else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// `self` if it's a web URL, otherwise nil.
    public var webURL: URL? { isWebURL ? self : nil }
}

public struct PRLabel: Hashable, Sendable {
    public let name: String
    /// Six-digit hex color without `#`, as GitHub returns it.
    public let color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

public struct Deployment: Hashable, Sendable {
    public let environment: String
    /// Latest deployment status state, uppercased (SUCCESS, FAILURE, IN_PROGRESS, ...).
    public let state: String
    public let environmentURL: URL?
    public let logURL: URL?
    public let updatedAt: Date
    /// The commit that was deployed.
    public let commitOID: String?

    public init(environment: String, state: String, environmentURL: URL?, logURL: URL?, updatedAt: Date, commitOID: String? = nil) {
        self.environment = environment
        self.state = state
        self.environmentURL = environmentURL
        self.logURL = logURL
        self.updatedAt = updatedAt
        self.commitOID = commitOID
    }

    /// Deployments often never get a final status. Treat in-progress ones that haven't changed in this long as abandoned.
    public static let staleAfter: TimeInterval = 3 * 60 * 60

    /// In progress and updated recently enough to believe it.
    public func isActive(now: Date = .now) -> Bool {
        phase == .inProgress && now.timeIntervalSince(updatedAt) < Self.staleAfter
    }

    public enum Phase: Sendable { case succeeded, failed, inProgress }

    public var phase: Phase {
        switch state {
        case "FAILURE", "ERROR": .failed
        case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING": .inProgress
        default: .succeeded // SUCCESS, ACTIVE, INACTIVE (superseded)
        }
    }
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repo: String
    public let author: String
    public var labels: [PRLabel]
    public var isDraft: Bool
    /// The PR branch's current commit.
    public let headOID: String?
    /// OPEN, MERGED, or CLOSED
    public let state: String
    public let updatedAt: Date
    public let mergedAt: Date?
    public let mergedBy: String?
    public let reviewDecision: String?
    public let mergeStateStatus: String?
    public let isInMergeQueue: Bool
    public let queuePosition: Int?
    public let queueState: String?
    public let autoMergeEnabled: Bool
    public let checks: ChecksSummary
    public let unresolvedThreads: Int
    public let totalComments: Int
    public let lastCommenter: String?
    public let approvals: [String]
    public let changesRequestedBy: [String]
    public let requestedReviewers: [String]
    public let deployments: [Deployment]
    public var relations: Set<Relation>
    /// Environments where this PR's code is live right now (see `GitHubClient.liveCommits`).
    public var liveEnvironments: [String]

    public init(
        id: String, number: Int, title: String, url: URL, repo: String, author: String,
        labels: [PRLabel] = [], isDraft: Bool = false, headOID: String? = nil, state: String = "OPEN", updatedAt: Date = .now,
        mergedAt: Date? = nil, mergedBy: String? = nil, reviewDecision: String? = nil,
        mergeStateStatus: String? = nil, isInMergeQueue: Bool = false, queuePosition: Int? = nil,
        queueState: String? = nil, autoMergeEnabled: Bool = false,
        checks: ChecksSummary = ChecksSummary(rollup: nil, items: []),
        unresolvedThreads: Int = 0, totalComments: Int = 0, lastCommenter: String? = nil,
        approvals: [String] = [], changesRequestedBy: [String] = [], requestedReviewers: [String] = [],
        deployments: [Deployment] = [], relations: Set<Relation> = [], liveEnvironments: [String] = []
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.author = author
        self.labels = labels
        self.isDraft = isDraft
        self.headOID = headOID
        self.state = state
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.mergedBy = mergedBy
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
        self.isInMergeQueue = isInMergeQueue
        self.queuePosition = queuePosition
        self.queueState = queueState
        self.autoMergeEnabled = autoMergeEnabled
        self.checks = checks
        self.unresolvedThreads = unresolvedThreads
        self.totalComments = totalComments
        self.lastCommenter = lastCommenter
        self.approvals = approvals
        self.changesRequestedBy = changesRequestedBy
        self.requestedReviewers = requestedReviewers
        self.deployments = deployments
        self.relations = relations
        self.liveEnvironments = liveEnvironments
    }

    public var isLive: Bool { !liveEnvironments.isEmpty }

    /// When the newest of its live deployments happened, for ordering.
    public var liveSince: Date? {
        relevantDeployments.filter { liveEnvironments.contains($0.environment) }.map(\.updatedAt).max()
    }

    public var isMerged: Bool { state == "MERGED" }
    public var isOpen: Bool { state == "OPEN" }
    public var checksURL: URL { url.appendingPathComponent("checks") }

    /// Deployments that describe where this PR's code is now: everything once merged,
    /// otherwise only deployments of the current head commit (older pushes don't matter).
    public var relevantDeployments: [Deployment] {
        guard !isMerged, let headOID else { return deployments }
        return deployments.filter { $0.commitOID == headOID }
    }
}
