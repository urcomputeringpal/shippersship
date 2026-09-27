import Foundation
import ShipKit

/// Made-up pull requests covering every pipeline state, for screenshots and the key-test harness
/// (`--demo`). Nothing here touches the network.
enum DemoData {
    static let viewer = "octocat"

    static let labels: [String: [RepoLabel]] = [
        "acme/rocket": [
            RepoLabel(id: "L1", name: "bug", color: "d73a4a", description: "Something isn't working"),
            RepoLabel(id: "L2", name: "deploy:production", color: "0e8a16", description: "Ship it to prod"),
            RepoLabel(id: "L3", name: "deploy:staging", color: "fbca04", description: "Ship it to staging"),
            RepoLabel(id: "L4", name: "documentation", color: "0075ca", description: nil),
            RepoLabel(id: "L5", name: "do not merge", color: "b60205", description: "Hold for now"),
            RepoLabel(id: "L6", name: "performance", color: "5319e7", description: nil),
        ],
    ]

    static func pullRequests(now: Date = .now) -> [PullRequest] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func url(_ repo: String, _ n: Int) -> URL { URL(string: "https://github.com/\(repo)/pull/\(n)")! }
        func checks(_ rollup: String, pass: Int, fail: [String] = [], pending: Int = 0) -> ChecksSummary {
            ChecksSummary(rollup: rollup, items:
                (0..<pass).map { CheckItem(name: "check \($0)", state: .success, url: nil) } +
                fail.map { CheckItem(name: $0, state: .failure, url: nil) } +
                (0..<pending).map { CheckItem(name: "pending \($0)", state: .pending, url: nil) })
        }
        let bug = PRLabel(name: "bug", color: "d73a4a")
        let perf = PRLabel(name: "performance", color: "5319e7")
        let docs = PRLabel(name: "documentation", color: "0075ca")
        let deps = PRLabel(name: "dependencies", color: "0366d6")
        let prod = { (state: String, minutes: Double) in
            Deployment(environment: "production", state: state, environmentURL: nil, logURL: nil, updatedAt: ago(minutes))
        }
        let staging = Deployment(environment: "staging", state: "SUCCESS", environmentURL: nil, logURL: nil, updatedAt: ago(30))

        return [
            PullRequest(id: "D1", number: 482, title: "Retry flaky launch sequence on cold starts", url: url("acme/rocket", 482),
                        repo: "acme/rocket", author: viewer, labels: [bug], updatedAt: ago(4), reviewDecision: "APPROVED",
                        mergeStateStatus: "BLOCKED", checks: checks("FAILURE", pass: 11, fail: ["integration / macOS"]),
                        totalComments: 3, relations: [.authored]),
            PullRequest(id: "D2", number: 1290, title: "Cache telemetry parsers between runs", url: url("acme/mission-control", 1290),
                        repo: "acme/mission-control", author: "hubot", labels: [perf], updatedAt: ago(15),
                        reviewDecision: "REVIEW_REQUIRED", mergeStateStatus: "BLOCKED", checks: checks("SUCCESS", pass: 8),
                        requestedReviewers: [viewer], relations: [.reviewRequested]),
            PullRequest(id: "D3", number: 479, title: "Document the countdown state machine", url: url("acme/rocket", 479),
                        repo: "acme/rocket", author: viewer, labels: [docs], updatedAt: ago(40), reviewDecision: "APPROVED",
                        mergeStateStatus: "CLEAN", checks: checks("SUCCESS", pass: 12), approvals: ["monalisa"], relations: [.authored]),
            PullRequest(id: "D4", number: 477, title: "Split guidance computer into modules", url: url("acme/rocket", 477),
                        repo: "acme/rocket", author: viewer, updatedAt: ago(55), reviewDecision: "APPROVED",
                        mergeStateStatus: "CLEAN", checks: checks("SUCCESS", pass: 12), unresolvedThreads: 2, totalComments: 9,
                        lastCommenter: "monalisa", approvals: ["monalisa"], relations: [.authored]),
            PullRequest(id: "D5", number: 486, title: "Stream fuel sensor readings over websockets", url: url("acme/rocket", 486),
                        repo: "acme/rocket", author: viewer, labels: [perf], updatedAt: ago(8), reviewDecision: "APPROVED",
                        isInMergeQueue: true, queuePosition: 2, queueState: "AWAITING_CHECKS",
                        checks: checks("PENDING", pass: 9, pending: 3), approvals: ["monalisa"], relations: [.authored]),
            PullRequest(id: "D6", number: 488, title: "Add abort button confirmation", url: url("acme/rocket", 488),
                        repo: "acme/rocket", author: viewer, updatedAt: ago(2), reviewDecision: "REVIEW_REQUIRED",
                        mergeStateStatus: "BLOCKED", autoMergeEnabled: true, checks: checks("PENDING", pass: 7, pending: 5),
                        requestedReviewers: ["monalisa"], relations: [.authored]),
            PullRequest(id: "D7", number: 1285, title: "Upgrade orbit simulator to v3", url: url("acme/mission-control", 1285),
                        repo: "acme/mission-control", author: "monalisa", updatedAt: ago(90), reviewDecision: "REVIEW_REQUIRED",
                        mergeStateStatus: "BLOCKED", checks: checks("SUCCESS", pass: 8), approvals: [viewer], relations: [.reviewed]),
            PullRequest(id: "D8", number: 470, title: "Prototype reusable boosters", url: url("acme/rocket", 470),
                        repo: "acme/rocket", author: viewer, isDraft: true, updatedAt: ago(60 * 26),
                        checks: checks("SUCCESS", pass: 12), relations: [.authored]),
            PullRequest(id: "D9", number: 475, title: "Speed up trajectory solver", url: url("acme/rocket", 475),
                        repo: "acme/rocket", author: viewer, labels: [perf], state: "MERGED", updatedAt: ago(20), mergedAt: ago(20),
                        mergedBy: viewer, checks: checks("SUCCESS", pass: 12), deployments: [prod("IN_PROGRESS", 3), staging],
                        relations: [.authored, .merged]),
            PullRequest(id: "D10", number: 474, title: "Fix off-by-one in stage separation timer", url: url("acme/rocket", 474),
                        repo: "acme/rocket", author: viewer, labels: [bug], state: "MERGED", updatedAt: ago(130), mergedAt: ago(130),
                        mergedBy: viewer, checks: checks("SUCCESS", pass: 12), deployments: [prod("SUCCESS", 100), staging],
                        relations: [.authored, .merged]),
            PullRequest(id: "D11", number: 1281, title: "Rotate ground station certificates", url: url("acme/mission-control", 1281),
                        repo: "acme/mission-control", author: "hubot", state: "MERGED", updatedAt: ago(300), mergedAt: ago(300),
                        mergedBy: viewer, checks: checks("SUCCESS", pass: 8), deployments: [prod("FAILURE", 280)],
                        relations: [.reviewed, .merged]),
            PullRequest(id: "D12", number: 468, title: "Tidy up launchpad fixtures", url: url("acme/rocket", 468),
                        repo: "acme/rocket", author: viewer, state: "MERGED", updatedAt: ago(60 * 20), mergedAt: ago(60 * 20),
                        mergedBy: viewer, checks: checks("SUCCESS", pass: 12), relations: [.authored, .merged]),
            PullRequest(id: "D13", number: 88, title: "Bump eslint from 9.1.0 to 9.2.0", url: url("acme/website", 88),
                        repo: "acme/website", author: "dependabot[bot]", labels: [deps], updatedAt: ago(200),
                        reviewDecision: "REVIEW_REQUIRED", mergeStateStatus: "BLOCKED", checks: checks("SUCCESS", pass: 4),
                        relations: [.reviewRequested]),
            PullRequest(id: "D14", number: 87, title: "Bump astro from 4.8.0 to 4.9.1", url: url("acme/website", 87),
                        repo: "acme/website", author: "dependabot[bot]", labels: [deps], updatedAt: ago(400),
                        reviewDecision: "REVIEW_REQUIRED", mergeStateStatus: "BLOCKED", checks: checks("FAILURE", pass: 3, fail: ["build"]),
                        relations: [.reviewRequested]),
        ]
    }

    static let groups = [PRGroup(name: "Dependency bumps", rules: ["author:dependabot", "label:dependencies"], quiet: true)]
}
