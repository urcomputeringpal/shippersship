import Foundation

extension GitHubClient {
    /// For each repo, which commit is live in each environment: the newest deployment whose latest status is SUCCESS.
    ///
    /// GitHub's own `ACTIVE` deployment state isn't reliable for this: many deploy tools never mark older
    /// deployments inactive, so everything they ever shipped stays "active".
    public func liveCommits(repos: [String]) async throws -> [String: [String: String]] {
        let repos = repos.filter { $0.split(separator: "/").count == 2 }
        guard !repos.isEmpty else { return [:] }
        var variables: [String: Any] = [:]
        var declarations: [String] = []
        var fields: [String] = []
        for (i, repo) in repos.enumerated() {
            let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
            variables["o\(i)"] = parts[0]
            variables["n\(i)"] = parts[1]
            declarations.append("$o\(i): String!, $n\(i): String!")
            fields.append("""
              r\(i): repository(owner: $o\(i), name: $n\(i)) {
                deployments(last: 50, orderBy: {field: CREATED_AT, direction: ASC}) {
                  nodes { environment commitOid createdAt latestStatus { state } }
                }
              }
            """)
        }
        let query = "query Live(\(declarations.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}"
        let body: [String: LiveRepo?] = try await graphQL(query, variables: variables)

        var result: [String: [String: String]] = [:]
        for (i, repo) in repos.enumerated() {
            result[repo] = Self.liveCommits(from: body["r\(i)"]??.deployments.nodes ?? [])
        }
        return result
    }

    /// Environment → commit of the newest successful deployment.
    static func liveCommits(from nodes: [LiveNode]) -> [String: String] {
        var live: [String: (commit: String, at: Date)] = [:]
        for node in nodes where node.latestStatus?.state == "SUCCESS" {
            guard let env = node.environment, let commit = node.commitOid else { continue }
            if let current = live[env], current.at > node.createdAt { continue }
            live[env] = (commit, node.createdAt)
        }
        return live.mapValues(\.commit)
    }

    struct LiveRepo: Decodable {
        struct Deployments: Decodable { let nodes: [LiveNode] }
        let deployments: Deployments
    }

    struct LiveNode: Decodable {
        struct Status: Decodable { let state: String }
        let environment: String?
        let commitOid: String?
        let createdAt: Date
        let latestStatus: Status?
    }
}

extension PullRequest {
    /// Environments where this PR's code is what's deployed right now, given each environment's live commit.
    public func liveEnvironments(liveCommits: [String: String]) -> [String] {
        relevantDeployments
            .filter { $0.phase == .succeeded && $0.commitOID != nil && liveCommits[$0.environment] == $0.commitOID }
            .map(\.environment)
            .sorted()
    }
}
