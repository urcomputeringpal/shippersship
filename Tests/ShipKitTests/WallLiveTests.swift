import Foundation
@testable import ShipKit
import Testing

/// Hits the real API as the wall's GitHub App when SHIPPERS_SHIP_WALL_LIVE=1, using the config `ShippersShipWall configure`
/// saved. Checks that an installation token can search, that search stays inside the installed repos, and that the
/// App has every permission the wall uses.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SHIPPERS_SHIP_WALL_LIVE"] == "1"))
func liveInstallation() async throws {
    let config = try WallConfig.load()
    let app = GitHubApp(appID: config.appID, key: try AppKey(pem: KeyFile.read(URL(filePath: config.keyFile))))
    let token = try await app.installationToken(config.installationID)
    let rest = GitHubREST()
    let client = GitHubClient(token: token.token)

    var installed: Set<String> = []
    for page in 1...10 {
        let repos: InstallationRepositories = try await rest.send("/installation/repositories?per_page=100&page=\(page)", bearer: token.token)
        installed.formUnion(repos.repositories.map(\.fullName))
        if installed.count >= repos.totalCount || repos.repositories.isEmpty { break }
    }
    print("installed on \(installed.count) repos: \(installed.sorted().joined(separator: ", "))")

    // Search, with the whole PR fragment the menu bar app uses, every page.
    let since = Date.now.addingTimeInterval(-24 * 60 * 60).formatted(.iso8601)
    for q in ["org:\(config.org) is:pr is:open archived:false", "org:\(config.org) is:pr is:merged merged:>=\(since)"] {
        var nodes: [SpikeSearch.Node] = []
        var cursor: String?
        var pages = 0
        var last: SpikeSearch?
        repeat {
            var variables: [String: Any] = ["q": q]
            if let cursor { variables["after"] = cursor }
            let body: SpikeSearch = try await client.graphQL(SpikeSearch.query, variables: variables)
            nodes += body.search.nodes
            cursor = body.search.pageInfo.hasNextPage ? body.search.pageInfo.endCursor : nil
            pages += 1
            last = body
        } while cursor != nil && pages < 10
        let body = try #require(last)

        let prs = nodes.compactMap(\.pr).map { $0.pullRequest(relations: []) }
        let privateRepos = Set(nodes.filter { $0.isPrivate == true }.compactMap(\.pr?.repository.nameWithOwner))
        let outside = Set(prs.map(\.repo)).subtracting(installed)
        print("\n\(q)\n  \(body.search.issueCount) results in \(pages) pages, \(prs.count) PRs, \(nodes.count - prs.count) failed to decode")
        print("  GraphQL rate limit \(body.rateLimit.remaining)/\(body.rateLimit.limit), each page cost \(body.rateLimit.cost)")
        print("  inside the installation: \(prs.filter { installed.contains($0.repo) }.count) PRs")
        for repo in outside.sorted() {
            let count = prs.filter { $0.repo == repo }.count
            print("  ! outside: \(repo) (\(privateRepos.contains(repo) ? "PRIVATE" : "public")), \(count) PRs")
        }
        for pr in prs.filter({ installed.contains($0.repo) }).sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(8) {
            print("    \(pr.repo)#\(pr.number) \(ShipStatus(for: pr).headline)")
        }
        // Any token can read public repos, so search returns their PRs whether or not the App is installed on them.
        // The wall has to scope its own searches. A private repo outside the installation would be a real leak.
        #expect(outside.intersection(privateRepos).isEmpty, "private repos outside the installation: \(outside.intersection(privateRepos).sorted())")
    }

    // `viewer` with an installation token.
    do {
        let viewer: SpikeViewer = try await client.graphQL("query { viewer { login } }", variables: [:])
        print("\nviewer: \(viewer.viewer.login)")
    } catch {
        print("\nviewer: \(error.localizedDescription)")
    }

    // The permissions the fragment doesn't cover: Actions, Contents and Self-hosted runners.
    print("\ntoken permissions: \(token.permissions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    let runners: SpikeCount = try await rest.send("/orgs/\(config.org)/actions/runners?per_page=1", bearer: token.token)
    print("org runners: \(runners.totalCount)")
    // Runners registered on a repository instead of the organization. These need Administration.
    for repo in installed.sorted() {
        do {
            let repoRunners: SpikeCount = try await rest.send("/repos/\(repo)/actions/runners?per_page=1", bearer: token.token)
            print("\(repo) runners: \(repoRunners.totalCount)")
        } catch {
            Issue.record("\(repo) runners: \(error.localizedDescription)")
        }
    }
    #expect(token.missingPermissions.isEmpty, "the App is missing \(token.missingPermissions)")
    if let repo = installed.sorted().first {
        let runs: SpikeCount = try await rest.send("/repos/\(repo)/actions/runs?per_page=1", bearer: token.token)
        print("\(repo) workflow runs: \(runs.totalCount)")
        let parts = repo.split(separator: "/").map(String.init)
        let history: SpikeHistory = try await client.graphQL(SpikeHistory.query, variables: ["o": parts[0], "n": parts[1]])
        let states = history.repository.defaultBranchRef?.target.history?.nodes.map { $0.statusCheckRollup?.state ?? "none" } ?? []
        print("\(repo) default branch, last \(states.count) commits: \(states.joined(separator: " "))")
    }
}

private struct SpikeSearch: Decodable {
    static let query = """
    query WallSpike($q: String!, $after: String) {
      rateLimit { limit remaining cost }
      search(query: $q, type: ISSUE, first: 25, after: $after) {
        issueCount pageInfo { hasNextPage endCursor }
        nodes { ...PR ... on PullRequest { repository { isPrivate } } }
      }
    }
    """ + "\n" + GitHubClient.fragments

    struct Limit: Decodable { let limit: Int; let remaining: Int; let cost: Int }
    struct Search: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [Node]
    }

    /// A PR, plus whether its repo is private.
    struct Node: Decodable {
        struct Repo: Decodable { let isPrivate: Bool }
        struct Wrapper: Decodable { let repository: Repo }
        let pr: GQL.PR?
        let isPrivate: Bool?
        init(from decoder: Decoder) throws {
            pr = try? GQL.PR(from: decoder)
            isPrivate = (try? Wrapper(from: decoder))?.repository.isPrivate
        }
    }

    let rateLimit: Limit
    let search: Search
}

private struct SpikeViewer: Decodable {
    struct Login: Decodable { let login: String }
    let viewer: Login
}

private struct SpikeCount: Decodable {
    let totalCount: Int
    enum CodingKeys: String, CodingKey { case totalCount = "total_count" }
}

private struct SpikeHistory: Decodable {
    static let query = """
    query WallSpikeHistory($o: String!, $n: String!) {
      repository(owner: $o, name: $n) {
        defaultBranchRef { target { ... on Commit { history(first: 5) { nodes { statusCheckRollup { state } } } } } }
      }
    }
    """

    struct Repository: Decodable {
        struct Ref: Decodable {
            struct Target: Decodable {
                struct History: Decodable {
                    struct Node: Decodable {
                        struct Rollup: Decodable { let state: String }
                        let statusCheckRollup: Rollup?
                    }
                    let nodes: [Node]
                }
                let history: History?
            }
            let target: Target
        }
        let defaultBranchRef: Ref?
    }

    let repository: Repository
}
