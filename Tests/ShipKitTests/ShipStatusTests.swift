import Foundation
@testable import ShipKit
import Testing

private func pr(
    state: String = "OPEN", isDraft: Bool = false, reviewDecision: String? = nil,
    mergeStateStatus: String? = "CLEAN", rollup: String? = "SUCCESS", items: [CheckItem] = [],
    isInMergeQueue: Bool = false, queueState: String? = nil, autoMerge: Bool = false,
    unresolved: Int = 0, deployments: [Deployment] = [], relations: Set<Relation> = [.authored]
) -> PullRequest {
    PullRequest(
        id: "PR_1", number: 42, title: "Ship it", url: URL(string: "https://github.com/o/r/pull/42")!,
        repo: "o/r", author: "me", isDraft: isDraft, state: state, mergedBy: state == "MERGED" ? "me" : nil,
        reviewDecision: reviewDecision, mergeStateStatus: mergeStateStatus, isInMergeQueue: isInMergeQueue,
        queuePosition: isInMergeQueue ? 2 : nil, queueState: queueState, autoMergeEnabled: autoMerge,
        checks: ChecksSummary(rollup: rollup, items: items), unresolvedThreads: unresolved,
        deployments: deployments, relations: relations
    )
}

private func deploy(_ env: String, _ state: String) -> Deployment {
    Deployment(environment: env, state: state, environmentURL: nil, logURL: nil, updatedAt: .now)
}

@Test func readyToMergeNeedsAuthor() {
    let s = ShipStatus(for: pr(reviewDecision: "APPROVED"))
    #expect(s.kind == .ready)
    #expect(s.needsAttention)
    #expect(s.pipeline == Pipeline(review: .done, checks: .done, merge: .ready, deploy: .pending))
}

@Test func failingCIWinsOverReview() {
    let failing = CheckItem(name: "test", state: .failure, url: nil)
    let s = ShipStatus(for: pr(reviewDecision: "CHANGES_REQUESTED", rollup: "FAILURE", items: [failing]))
    #expect(s.kind == .ciFailing)
    #expect(s.headline == "CI failing: test")
    #expect(s.tone == .bad)
}

@Test func reviewRequestedOfViewer() {
    let s = ShipStatus(for: pr(reviewDecision: "REVIEW_REQUIRED", relations: [.reviewRequested]))
    #expect(s.kind == .reviewRequested)
    #expect(s.needsAttention)
}

@Test func reviewersAreNotNaggedAboutOthersCI() {
    let s = ShipStatus(for: pr(rollup: "FAILURE", relations: [.reviewed]))
    #expect(s.kind == .ciFailing)
    #expect(!s.needsAttention)
}

@Test func mergeQueue() {
    let s = ShipStatus(for: pr(reviewDecision: "APPROVED", isInMergeQueue: true, queueState: "AWAITING_CHECKS"))
    #expect(s.kind == .queued)
    #expect(s.headline == "In merge queue · #2")
    #expect(s.pipeline.merge == .active)

    let kicked = ShipStatus(for: pr(isInMergeQueue: true, queueState: "UNMERGEABLE"))
    #expect(kicked.kind == .queueFailed)
    #expect(kicked.pipeline.merge == .failed)
}

@Test func conflictsAndUnresolvedThreads() {
    #expect(ShipStatus(for: pr(mergeStateStatus: "DIRTY")).kind == .conflicts)
    let threads = ShipStatus(for: pr(reviewDecision: "APPROVED", unresolved: 2))
    #expect(threads.kind == .unresolved)
    #expect(threads.headline == "2 unresolved threads")
}

@Test func autoMergeIsNotAnAction() {
    let s = ShipStatus(for: pr(reviewDecision: "APPROVED", mergeStateStatus: "BLOCKED", rollup: "PENDING", autoMerge: true))
    #expect(s.kind == .ciRunning)
    #expect(!s.needsAttention)
    #expect(s.detail == "auto-merge on")
}

@Test func deploymentLifecycle() {
    let merged = ShipStatus(for: pr(state: "MERGED"))
    #expect(merged.kind == .merged)
    #expect(merged.pipeline.deploy == .skipped)

    let deploying = ShipStatus(for: pr(state: "MERGED", deployments: [deploy("staging", "SUCCESS"), deploy("production", "IN_PROGRESS")]))
    #expect(deploying.kind == .deploying)
    #expect(deploying.headline == "Deploying to production")

    let deployed = ShipStatus(for: pr(state: "MERGED", deployments: [deploy("production", "SUCCESS")]))
    #expect(deployed.kind == .deployed)
    #expect(deployed.pipeline == Pipeline(review: .done, checks: .done, merge: .done, deploy: .done))

    let failed = ShipStatus(for: pr(state: "MERGED", deployments: [deploy("production", "FAILURE")]))
    #expect(failed.kind == .deployFailed)
    #expect(failed.needsAttention)
}

@Test func decodesSearchResponseAndDerivesRelations() throws {
    let json = """
    {"data":{"viewer":{"login":"me"},"rateLimit":{"remaining":4999,"resetAt":"2026-09-26T00:00:00Z"},
    "search":{"nodes":[{},
      {"id":"A","number":1,"title":"Mine","url":"https://github.com/o/r/pull/1","isDraft":false,"state":"MERGED",
       "updatedAt":"2026-09-25T00:00:00Z","mergedAt":"2026-09-25T00:00:00Z","author":{"login":"me"},"mergedBy":{"login":"me"},
       "repository":{"nameWithOwner":"o/r"},"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN","isInMergeQueue":false,
       "mergeQueueEntry":null,"autoMergeRequest":null,"totalCommentsCount":3,"comments":{"nodes":[{"author":{"login":"bot"}}]},
       "reviewThreads":{"nodes":[{"isResolved":false},{"isResolved":true}]},
       "latestReviews":{"nodes":[{"state":"APPROVED","author":{"login":"pal"}}]},"reviewRequests":{"nodes":[]},
       "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[
         {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":null},
         {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","targetUrl":null}]}}}}]},
       "mergeCommit":{"deployments":{"nodes":[
         {"environment":"production","state":"IN_PROGRESS","createdAt":"2026-09-25T00:00:00Z","updatedAt":"2026-09-25T00:01:00Z","latestStatus":null}]}},
       "timelineItems":{"nodes":[{"deployment":
         {"environment":"production","state":"ACTIVE","createdAt":"2026-09-25T00:00:00Z","updatedAt":"2026-09-25T00:05:00Z",
          "latestStatus":{"state":"SUCCESS","environmentUrl":"https://example.com","logUrl":null,"createdAt":"2026-09-25T00:05:00Z"}}}]}},
      {"id":"B","number":2,"title":"Just mentioned","url":"https://github.com/o/r/pull/2","isDraft":false,"state":"MERGED",
       "updatedAt":"2026-09-25T00:00:00Z","mergedAt":"2026-09-25T00:00:00Z","author":{"login":"other"},"mergedBy":{"login":"other"},
       "repository":{"nameWithOwner":"o/r"},"reviewDecision":null,"mergeStateStatus":null,"isInMergeQueue":false,
       "mergeQueueEntry":null,"autoMergeRequest":null,"totalCommentsCount":0,"comments":{"nodes":[]},
       "reviewThreads":{"nodes":[]},"latestReviews":{"nodes":[]},"reviewRequests":{"nodes":[]},"commits":{"nodes":[]},
       "mergeCommit":null,"timelineItems":{"nodes":[]}}
    ]}}}
    """
    let empty: GQL.Body = try GitHubClient.decode(Data(#"{"data":{"viewer":{"login":"me"},"search":{"nodes":[]}}}"#.utf8))
    let merged: GQL.Body = try GitHubClient.decode(Data(json.utf8))
    let snapshot = GitHubClient.merge(authored: empty, requested: empty, reviewed: empty, merged: merged)
    #expect(snapshot.rateLimitRemaining == 4999)
    #expect(snapshot.viewer == "me")
    #expect(snapshot.pullRequests.count == 1)

    let mine = try #require(snapshot.pullRequests.first)
    #expect(mine.relations == [.authored, .merged])
    #expect(mine.unresolvedThreads == 1)
    #expect(mine.lastCommenter == "bot")
    #expect(mine.checks.items.count == 2)
    #expect(mine.deployments.count == 1)
    #expect(mine.deployments.first?.state == "SUCCESS")
    #expect(ShipStatus(for: mine).kind == .deployed)
}

/// Hits the real API when SHIPPERS_SHIP_LIVE=1 (uses GITHUB_TOKEN or `gh auth token`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIPPERS_SHIP_LIVE"] == "1"))
func liveSnapshot() async throws {
    let token = try #require(await TokenProvider.resolve()).token
    let snapshot = try await GitHubClient(token: token).fetch(mergedWithinDays: 3)
    print("viewer @\(snapshot.viewer), \(snapshot.pullRequests.count) PRs, rate limit \(snapshot.rateLimitRemaining ?? -1)")
    for pr in snapshot.pullRequests.sorted(by: { $0.updatedAt > $1.updatedAt }) {
        let s = ShipStatus(for: pr)
        let p = s.pipeline
        print(String(format: "%@ %-38@ %@ | R:%@ C:%@ M:%@ D:%@ | %@",
                     s.needsAttention ? "!" : " ", "\(pr.repo)#\(pr.number)" as NSString, s.headline,
                     "\(p.review)", "\(p.checks)", "\(p.merge)", "\(p.deploy)", pr.relations.map(\.rawValue).sorted().joined(separator: ",")))
    }
}

@Test func openPRDeploysOfHeadCommit() {
    let now = Date()
    func dep(_ state: String, commit: String, minutesAgo: Double = 1) -> Deployment {
        Deployment(environment: "testflight", state: state, environmentURL: nil, logURL: nil,
                   updatedAt: now.addingTimeInterval(-minutesAgo * 60), commitOID: commit)
    }
    func open(_ deployments: [Deployment]) -> PullRequest {
        PullRequest(id: "1", number: 1, title: "t", url: URL(string: "https://github.com/o/r/pull/1")!, repo: "o/r",
                    author: "me", headOID: "head", reviewDecision: "APPROVED", mergeStateStatus: "BLOCKED",
                    checks: ChecksSummary(rollup: "SUCCESS", items: []), deployments: deployments, relations: [.authored])
    }

    let queued = ShipStatus(for: open([dep("QUEUED", commit: "head")]), now: now)
    #expect(queued.kind == .deploying)
    #expect(queued.headline == "Deploy queued · testflight")
    #expect(queued.pipeline.deploy == .active)

    #expect(ShipStatus(for: open([dep("IN_PROGRESS", commit: "head")]), now: now).headline == "Deploying to testflight")

    let failed = ShipStatus(for: open([dep("FAILURE", commit: "head")]), now: now)
    #expect(failed.kind == .deployFailed)
    #expect(failed.needsAttention)

    // Deploys of earlier pushes don't count.
    let old = ShipStatus(for: open([dep("FAILURE", commit: "older")]), now: now)
    #expect(old.kind == .blocked)
    #expect(old.pipeline.deploy == .pending)

    // Stuck in QUEUED for hours: treat as abandoned, not in flight.
    let stale = ShipStatus(for: open([dep("QUEUED", commit: "head", minutesAgo: 4 * 60)]), now: now)
    #expect(stale.kind != .deploying)
}

@Test func onlyWebURLsSurviveDecoding() {
    #expect(URL(string: "https://github.com/o/r/runs/1")!.isWebURL)
    #expect(URL(string: "HTTP://ci.example.com/x")!.isWebURL)
    for unsafe in ["file:///etc/passwd", "smb://attacker.example/share", "vscode://ext/install", "javascript:alert(1)", "https:nohost"] {
        #expect(URL(string: unsafe)?.isWebURL != true, "\(unsafe) should be rejected")
    }

    let context = GQL.Context(__typename: "StatusContext", name: nil, status: nil, conclusion: nil, detailsUrl: nil,
                              context: "ci", state: "FAILURE", targetUrl: URL(string: "smb://attacker.example/share"))
    #expect(context.checkItem.url == nil)
    let run = GQL.Context(__typename: "CheckRun", name: "build", status: "COMPLETED", conclusion: "FAILURE",
                          detailsUrl: URL(string: "https://ci.example.com/1"), context: nil, state: nil, targetUrl: nil)
    #expect(run.checkItem.url?.host == "ci.example.com")
}
