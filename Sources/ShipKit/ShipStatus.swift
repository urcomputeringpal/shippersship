import Foundation

/// State of one stage in the Review → CI → Merge → Deploy pipeline.
public enum StepStatus: Hashable, Sendable {
    case pending   // not reached yet
    case active    // in progress
    case ready     // clear to proceed (e.g. mergeable)
    case blocked   // waiting on something other than a failure
    case failed
    case done
    case skipped   // not applicable (no required reviews, no checks, no deployments)
}

public struct Pipeline: Hashable, Sendable {
    public var review: StepStatus
    public var checks: StepStatus
    public var merge: StepStatus
    public var deploy: StepStatus
}

public enum StatusKind: String, Hashable, Sendable {
    case draft, reviewRequested, awaitingReview, changesRequested
    case ciFailing, ciRunning, conflicts, behind, blocked, unresolved
    case ready, queued, queueFailed
    case merged, deploying, deployed, deployFailed, closed
}

public enum Tone: Hashable, Sendable {
    case neutral, progress, good, warning, bad
}

public struct ShipStatus: Hashable, Sendable {
    public let kind: StatusKind
    public let headline: String
    public let detail: String?
    public let tone: Tone
    public let needsAttention: Bool
    public let pipeline: Pipeline

    public init(for pr: PullRequest, now: Date = .now) {
        let pipeline = Self.pipeline(for: pr, now: now)
        let (kind, headline, detail, tone, attention) = Self.headline(for: pr, pipeline: pipeline, now: now)
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.tone = tone
        self.needsAttention = attention
        self.pipeline = pipeline
    }

    // MARK: - Pipeline

    static func pipeline(for pr: PullRequest, now: Date = .now) -> Pipeline {
        Pipeline(
            review: reviewStep(pr),
            checks: checksStep(pr),
            merge: mergeStep(pr),
            deploy: deployStep(pr, now: now)
        )
    }

    static func reviewStep(_ pr: PullRequest) -> StepStatus {
        if pr.isMerged { return .done }
        switch pr.reviewDecision {
        case "APPROVED": return .done
        case "CHANGES_REQUESTED": return .failed
        case "REVIEW_REQUIRED": return pr.isDraft ? .pending : .active
        default:
            if !pr.changesRequestedBy.isEmpty { return .failed }
            if !pr.approvals.isEmpty { return .done }
            return pr.isDraft ? .pending : .skipped
        }
    }

    static func checksStep(_ pr: PullRequest) -> StepStatus {
        switch pr.checks.rollup {
        case "SUCCESS": .done
        case "FAILURE", "ERROR": .failed
        case "PENDING", "EXPECTED": .active
        default: .skipped
        }
    }

    static func mergeStep(_ pr: PullRequest) -> StepStatus {
        if pr.isMerged { return .done }
        if !pr.isOpen { return .skipped }
        if pr.isInMergeQueue { return pr.queueState == "UNMERGEABLE" ? .failed : .active }
        if pr.isDraft { return .pending }
        switch pr.mergeStateStatus {
        case "DIRTY": return .failed
        case "CLEAN", "HAS_HOOKS", "UNSTABLE": return .ready
        case "BEHIND": return .blocked
        default: return pr.autoMergeEnabled ? .active : .pending
        }
    }

    /// Open PRs can be deployed too (previews, TestFlight, deploy-on-label); only their head commit counts.
    static func deployStep(_ pr: PullRequest, now: Date = .now) -> StepStatus {
        let deployments = pr.relevantDeployments
        if deployments.isEmpty { return pr.isMerged ? .skipped : .pending }
        if deployments.contains(where: { $0.phase == .failed }) { return .failed }
        if deployments.contains(where: { $0.isActive(now: now) }) { return .active }
        return .done
    }

    /// "Deploying to x" once something is running; "Deploy queued · x" while everything is still waiting to start.
    private static func deployingHeadline(_ pr: PullRequest, now: Date) -> String {
        let active = pr.relevantDeployments.filter { $0.isActive(now: now) }
        let envs = active.map(\.environment).joined(separator: ", ")
        return active.contains { $0.state == "IN_PROGRESS" } ? "Deploying to \(envs)" : "Deploy queued · \(envs)"
    }

    // MARK: - Headline

    private typealias Headline = (StatusKind, String, String?, Tone, Bool)

    private static func headline(for pr: PullRequest, pipeline: Pipeline, now: Date) -> Headline {
        let mine = pr.relations.contains(.authored)
        let owner = mine || pr.relations.contains(.merged)

        if pr.isMerged {
            let by = pr.mergedBy.map { "Merged by @\($0)" } ?? "Merged"
            let envs = { (ds: [Deployment]) in ds.map(\.environment).joined(separator: ", ") }
            switch pipeline.deploy {
            case .failed:
                return (.deployFailed, "Deploy failed: \(envs(pr.deployments.filter { $0.phase == .failed }))", by, .bad, owner)
            case .active:
                return (.deploying, deployingHeadline(pr, now: now), by, .progress, false)
            case .done:
                return (.deployed, "Deployed to \(envs(pr.deployments))", by, .good, false)
            default:
                return (.merged, by, nil, .good, false)
            }
        }

        if !pr.isOpen { return (.closed, "Closed", nil, .neutral, false) }

        // A deploy of the PR's current head: the most time-sensitive thing about an open PR.
        switch pipeline.deploy {
        case .active:
            return (.deploying, deployingHeadline(pr, now: now), checksDetail(pr), .progress, false)
        case .failed:
            let failed = pr.relevantDeployments.filter { $0.phase == .failed }.map(\.environment).joined(separator: ", ")
            return (.deployFailed, "Deploy failed: \(failed)", checksDetail(pr), .bad, mine)
        default:
            break
        }

        if !mine && pr.relations.contains(.reviewRequested) && !pr.isDraft {
            return (.reviewRequested, "Your review is requested", "by @\(pr.author)", .warning, true)
        }

        if pr.isDraft { return (.draft, "Draft", checksDetail(pr), .neutral, false) }

        if pr.isInMergeQueue {
            if pr.queueState == "UNMERGEABLE" {
                return (.queueFailed, "Merge queue can't merge this", checksDetail(pr), .bad, mine)
            }
            let pos = pr.queuePosition.map { "In merge queue · #\($0)" } ?? "In merge queue"
            let state = pr.queueState.map { $0.replacingOccurrences(of: "_", with: " ").lowercased() }
            return (.queued, pos, state, .progress, false)
        }

        let failed = pr.checks.failed
        if pipeline.checks == .failed {
            let names = failed.prefix(2).map(\.name).joined(separator: ", ")
            let more = failed.count > 2 ? " +\(failed.count - 2)" : ""
            return (.ciFailing, failed.isEmpty ? "CI failing" : "CI failing: \(names)\(more)", nil, .bad, mine)
        }

        if pipeline.review == .failed {
            let who = pr.changesRequestedBy.map { "@\($0)" }.joined(separator: ", ")
            return (.changesRequested, "Changes requested", who.isEmpty ? nil : "by \(who)", .warning, mine)
        }

        if pr.mergeStateStatus == "DIRTY" {
            return (.conflicts, "Merge conflicts", nil, .bad, mine)
        }

        if mine && pr.unresolvedThreads > 0 {
            let s = pr.unresolvedThreads == 1 ? "" : "s"
            return (.unresolved, "\(pr.unresolvedThreads) unresolved thread\(s)", reviewDetail(pr), .warning, true)
        }

        if pipeline.checks == .active {
            let done = pr.checks.passed.count
            let detail = pr.autoMergeEnabled ? "auto-merge on" : nil
            return (.ciRunning, "CI running · \(done)/\(pr.checks.items.count)", detail, .progress, false)
        }

        if pipeline.review == .active {
            return (.awaitingReview, "Awaiting review", reviewDetail(pr), .neutral, false)
        }

        switch pr.mergeStateStatus {
        case "BEHIND":
            return (.behind, "Branch is behind base", nil, .warning, mine && !pr.autoMergeEnabled)
        case "BLOCKED":
            return (.blocked, "Blocked by branch protection", reviewDetail(pr), .warning, false)
        default:
            if pr.autoMergeEnabled {
                return (.ready, "Auto-merge enabled", reviewDetail(pr), .progress, false)
            }
            return (.ready, "Ready to merge", reviewDetail(pr), .good, mine)
        }
    }

    private static func checksDetail(_ pr: PullRequest) -> String? {
        guard !pr.checks.items.isEmpty else { return nil }
        return "\(pr.checks.passed.count)/\(pr.checks.items.count) checks passing"
    }

    private static func reviewDetail(_ pr: PullRequest) -> String? {
        if !pr.approvals.isEmpty {
            return "approved by " + pr.approvals.map { "@\($0)" }.joined(separator: ", ")
        }
        if !pr.requestedReviewers.isEmpty {
            return "waiting on " + pr.requestedReviewers.map { "@\($0)" }.joined(separator: ", ")
        }
        return nil
    }
}
