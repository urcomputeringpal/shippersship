import Foundation

public struct GitHubClient: Sendable {
    public struct Snapshot: Sendable {
        public let viewer: String
        public internal(set) var pullRequests: [PullRequest]
        public let rateLimitRemaining: Int?
    }

    public enum ClientError: LocalizedError {
        case http(Int, String)
        case graphQL([String])

        public var errorDescription: String? {
            switch self {
            case .http(401, _): "GitHub rejected the token (401). Re-run `gh auth login` or paste a new token."
            case let .http(code, body): "GitHub returned HTTP \(code): \(body.prefix(200))"
            case let .graphQL(messages): messages.joined(separator: "\n")
            }
        }
    }

    let token: String
    let endpoint: URL
    let session: URLSession

    public init(token: String, endpoint: URL = URL(string: "https://api.github.com/graphql")!, session: URLSession = .shared) {
        self.token = token
        self.endpoint = endpoint
        self.session = session
    }

    /// - Parameters:
    ///   - days: how far back to show merged PRs.
    ///   - activeDays: hide open PRs with no activity in this many days (0 shows everything).
    public func fetch(mergedWithinDays days: Int, activeWithinDays activeDays: Int = 0) async throws -> Snapshot {
        func dayString(_ n: Int) -> String {
            (Calendar.current.date(byAdding: .day, value: -n, to: .now) ?? .now).formatted(.iso8601.year().month().day())
        }
        let sinceString = dayString(max(days, 1))
        let open = "is:pr is:open archived:false" + (activeDays > 0 ? " updated:>=\(dayString(activeDays))" : "")

        // One request per search: combining them into a single query regularly times out on GitHub's side.
        async let authored = search("\(open) author:@me")
        async let requested = search("\(open) review-requested:@me")
        async let reviewed = search("\(open) reviewed-by:@me -author:@me")
        async let merged = search("is:pr is:merged involves:@me merged:>=\(sinceString)")
        let results = try await (authored, requested, reviewed, merged)
        var snapshot = Self.merge(authored: results.0, requested: results.1, reviewed: results.2, merged: results.3)

        // Work out what's live. Best effort: if this fails, PRs just don't get marked live.
        let repos = Set(snapshot.pullRequests.filter { !$0.deployments.isEmpty }.map(\.repo)).sorted()
        if let live = try? await liveCommits(repos: repos) {
            snapshot.pullRequests = snapshot.pullRequests.map { pr in
                var pr = pr
                pr.liveEnvironments = pr.liveEnvironments(liveCommits: live[pr.repo] ?? [:])
                return pr
            }
        }
        return snapshot
    }

    private func search(_ q: String) async throws -> GQL.Body {
        try await graphQL(Self.query, variables: ["q": q])
    }

    /// POSTs a GraphQL document and decodes its `data` payload.
    func graphQL<T: Decodable>(_ query: String, variables: [String: Any]) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ShippersShip", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClientError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try Self.decode(data)
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(GQL.Response<T>.self, from: data)
        guard let body = response.data, response.errors?.isEmpty ?? true else {
            throw ClientError.graphQL(response.errors?.map(\.message) ?? ["Empty response from GitHub"])
        }
        return body
    }

    static func merge(authored: GQL.Body, requested: GQL.Body, reviewed: GQL.Body, merged: GQL.Body) -> Snapshot {
        let viewer = authored.viewer.login

        var byID: [String: PullRequest] = [:]
        func add(_ body: GQL.Body, _ relations: (GQL.PR) -> Set<Relation>) {
            for raw in body.search.nodes.compactMap(\.value) {
                let rels = relations(raw)
                guard !rels.isEmpty else { continue }
                if var existing = byID[raw.id] {
                    existing.relations.formUnion(rels)
                    byID[raw.id] = existing
                } else {
                    byID[raw.id] = raw.pullRequest(relations: rels)
                }
            }
        }

        let derived = { (raw: GQL.PR) -> Set<Relation> in
            var r: Set<Relation> = []
            if raw.author?.login == viewer { r.insert(.authored) }
            if raw.mergedBy?.login == viewer { r.insert(.merged) }
            if raw.latestReviews.items.contains(where: { $0.author?.login == viewer }) { r.insert(.reviewed) }
            return r
        }
        add(authored) { derived($0).union([.authored]) }
        add(requested) { derived($0).union([.reviewRequested]) }
        add(reviewed) { derived($0).union([.reviewed]) }
        // `involves:` also matches mentions and comments; keep only PRs we wrote, reviewed, or merged.
        add(merged, derived)

        let remaining = [authored, requested, reviewed, merged].compactMap(\.rateLimit?.remaining).min()
        return Snapshot(viewer: viewer, pullRequests: Array(byID.values), rateLimitRemaining: remaining)
    }

    static let query = """
    query ShippersShip($q: String!) {
      viewer { login }
      rateLimit { remaining resetAt }
      search(query: $q, type: ISSUE, first: 25) { nodes { ...PR } }
    }
    fragment Dep on Deployment {
      environment state createdAt updatedAt commitOid
      latestStatus { state environmentUrl logUrl createdAt }
    }
    fragment PR on PullRequest {
      id number title url isDraft state updatedAt mergedAt headRefOid
      author { login }
      mergedBy { login }
      repository { nameWithOwner }
      labels(first: 20) { nodes { name color } }
      reviewDecision mergeStateStatus
      isInMergeQueue
      mergeQueueEntry { position state }
      autoMergeRequest { enabledAt }
      totalCommentsCount
      comments(last: 1) { nodes { author { login } } }
      reviewThreads(first: 50) { nodes { isResolved } }
      latestReviews(first: 10) { nodes { state author { login } } }
      reviewRequests(first: 10) {
        nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } ... on Bot { login } } }
      }
      commits(last: 1) {
        nodes { commit { statusCheckRollup { state contexts(first: 50) { nodes {
          __typename
          ... on CheckRun { name status conclusion detailsUrl }
          ... on StatusContext { context state targetUrl }
        } } } } }
      }
      mergeCommit { deployments(last: 5) { nodes { ...Dep } } }
      timelineItems(last: 5, itemTypes: [DEPLOYED_EVENT]) {
        nodes { ... on DeployedEvent { deployment { ...Dep } } }
      }
    }
    """
}

// MARK: - Wire format

enum GQL {
    struct Response<T: Decodable>: Decodable {
        let data: T?
        let errors: [Message]?
    }

    struct Message: Decodable { let message: String }

    struct Body: Decodable {
        let viewer: Login
        let rateLimit: RateLimit?
        let search: Search
    }

    struct RateLimit: Decodable { let remaining: Int }
    struct Login: Decodable { let login: String }
    struct Search: Decodable { let nodes: [Lossy<PR>] }

    /// Skips nodes that fail to decode (e.g. empty objects for non-PR results) instead of failing the whole response.
    struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    struct Nodes<T: Decodable>: Decodable {
        let nodes: [T?]?
        var items: [T] { nodes?.compactMap { $0 } ?? [] }
    }

    struct PR: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let isDraft: Bool
        let headRefOid: String?
        let state: String
        let updatedAt: Date
        let mergedAt: Date?
        let author: Login?
        let mergedBy: Login?
        let repository: Repository
        let labels: Nodes<PRLabelNode>?
        let reviewDecision: String?
        let mergeStateStatus: String?
        let isInMergeQueue: Bool?
        let mergeQueueEntry: QueueEntry?
        let autoMergeRequest: AutoMerge?
        let totalCommentsCount: Int?
        let comments: Nodes<Comment>
        let reviewThreads: Nodes<Thread>
        let latestReviews: Nodes<Review>
        let reviewRequests: Nodes<ReviewRequest>
        let commits: Nodes<CommitNode>
        let mergeCommit: MergeCommit?
        let timelineItems: Nodes<DeployedEvent>
    }

    struct Repository: Decodable { let nameWithOwner: String }
    struct PRLabelNode: Decodable { let name: String; let color: String }
    struct QueueEntry: Decodable { let position: Int?; let state: String? }
    struct AutoMerge: Decodable { let enabledAt: Date? }
    struct Comment: Decodable { let author: Login? }
    struct Thread: Decodable { let isResolved: Bool }
    struct Review: Decodable { let state: String; let author: Login? }

    struct ReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String?; let slug: String? }
        let requestedReviewer: Reviewer?
    }

    struct CommitNode: Decodable {
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        let commit: Commit
    }

    struct Rollup: Decodable {
        let state: String
        let contexts: Nodes<Context>
    }

    struct Context: Decodable {
        let __typename: String
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: URL?
        let context: String?
        let state: String?
        let targetUrl: URL?
    }

    struct MergeCommit: Decodable { let deployments: Nodes<Dep> }
    struct DeployedEvent: Decodable { let deployment: Dep? }

    struct Dep: Decodable {
        struct Status: Decodable {
            let state: String
            let environmentUrl: URL?
            let logUrl: URL?
            let createdAt: Date
        }
        let environment: String?
        let state: String?
        let updatedAt: Date
        let commitOid: String?
        let latestStatus: Status?
    }
}

// MARK: - Mapping

extension GQL.Context {
    var checkItem: CheckItem {
        if __typename == "StatusContext" {
            let s: CheckItemState = switch state {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            default: .pending
            }
            return CheckItem(name: context ?? "status", state: s, url: targetUrl?.webURL)
        }
        let s: CheckItemState
        if status != "COMPLETED" {
            s = .pending
        } else {
            s = switch conclusion {
            case "SUCCESS": .success
            case "NEUTRAL", "SKIPPED", "STALE": .neutral
            default: .failure // FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE
            }
        }
        return CheckItem(name: name ?? "check", state: s, url: detailsUrl?.webURL)
    }
}

extension GQL.Dep {
    var deployment: Deployment? {
        guard let environment else { return nil }
        return Deployment(
            environment: environment,
            state: (latestStatus?.state ?? state ?? "PENDING").uppercased(),
            environmentURL: latestStatus?.environmentUrl?.webURL,
            logURL: latestStatus?.logUrl?.webURL,
            updatedAt: latestStatus?.createdAt ?? updatedAt,
            commitOID: commitOid
        )
    }
}

extension GQL.PR {
    func pullRequest(relations: Set<Relation>) -> PullRequest {
        let rollup = commits.items.last?.commit.statusCheckRollup
        let reviews = latestReviews.items

        // Deployments of the merge commit plus "deployed" timeline events; keep the newest per environment.
        let allDeployments = (mergeCommit?.deployments.items ?? []) + timelineItems.items.compactMap(\.deployment)
        var latestByEnv: [String: Deployment] = [:]
        for d in allDeployments.compactMap(\.deployment) {
            // Open PRs only care about the head commit's deployments, so keep the newest per environment *and* commit.
            let key = state == "MERGED" ? d.environment : "\(d.environment)@\(d.commitOID ?? "")"
            if let current = latestByEnv[key], current.updatedAt >= d.updatedAt { continue }
            latestByEnv[key] = d
        }

        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repo: repository.nameWithOwner,
            author: author?.login ?? "ghost",
            labels: labels?.items.map { PRLabel(name: $0.name, color: $0.color) } ?? [],
            isDraft: isDraft,
            headOID: headRefOid,
            state: state,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            mergedBy: mergedBy?.login,
            reviewDecision: reviewDecision,
            mergeStateStatus: mergeStateStatus,
            isInMergeQueue: isInMergeQueue ?? false,
            queuePosition: mergeQueueEntry?.position,
            queueState: mergeQueueEntry?.state,
            autoMergeEnabled: autoMergeRequest != nil,
            checks: ChecksSummary(rollup: rollup?.state, items: rollup?.contexts.items.map(\.checkItem) ?? []),
            unresolvedThreads: reviewThreads.items.filter { !$0.isResolved }.count,
            totalComments: totalCommentsCount ?? 0,
            lastCommenter: comments.items.last?.author?.login,
            approvals: reviews.filter { $0.state == "APPROVED" }.compactMap(\.author?.login),
            changesRequestedBy: reviews.filter { $0.state == "CHANGES_REQUESTED" }.compactMap(\.author?.login),
            requestedReviewers: reviewRequests.items.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.slug },
            deployments: latestByEnv.values.sorted { $0.environment < $1.environment },
            relations: relations
        )
    }
}
