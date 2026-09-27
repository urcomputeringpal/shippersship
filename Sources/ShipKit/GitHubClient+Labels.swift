import Foundation

public struct RepoLabel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let description: String?

    public init(id: String, name: String, color: String, description: String?) {
        self.id = id
        self.name = name
        self.color = color
        self.description = description
    }
}

extension GitHubClient {
    /// All labels defined in `owner/name`, paging through repos with more than 100.
    public func labels(inRepo repo: String) async throws -> [RepoLabel] {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        var labels: [RepoLabel] = []
        var cursor: String?
        repeat {
            var variables: [String: Any] = ["owner": parts[0], "name": parts[1]]
            if let cursor { variables["after"] = cursor }
            let body: LabelsBody = try await graphQL(Self.labelsQuery, variables: variables)
            guard let connection = body.repository?.labels else { break }
            labels += connection.nodes.map { RepoLabel(id: $0.id, name: $0.name, color: $0.color, description: $0.description) }
            cursor = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : nil
        } while cursor != nil && labels.count < 1000
        return labels
    }

    /// Adds and removes labels on a PR and returns the labels it ends up with.
    public func updateLabels(pullRequestID: String, add: [String], remove: [String]) async throws -> [PRLabel] {
        var result: [PRLabel]?
        if !add.isEmpty {
            let body: AddBody = try await graphQL(Self.addMutation, variables: ["id": pullRequestID, "labels": add])
            result = body.addLabelsToLabelable?.labelable?.labels?.nodes.map { PRLabel(name: $0.name, color: $0.color) }
        }
        if !remove.isEmpty {
            let body: RemoveBody = try await graphQL(Self.removeMutation, variables: ["id": pullRequestID, "labels": remove])
            result = body.removeLabelsFromLabelable?.labelable?.labels?.nodes.map { PRLabel(name: $0.name, color: $0.color) }
        }
        return result ?? []
    }

    static let labelsQuery = """
    query RepoLabels($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        labels(first: 100, after: $after, orderBy: {field: NAME, direction: ASC}) {
          nodes { id name color description }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    static let addMutation = """
    mutation AddLabels($id: ID!, $labels: [ID!]!) {
      addLabelsToLabelable(input: {labelableId: $id, labelIds: $labels}) {
        labelable { ... on PullRequest { labels(first: 50) { nodes { name color } } } }
      }
    }
    """

    static let removeMutation = """
    mutation RemoveLabels($id: ID!, $labels: [ID!]!) {
      removeLabelsFromLabelable(input: {labelableId: $id, labelIds: $labels}) {
        labelable { ... on PullRequest { labels(first: 50) { nodes { name color } } } }
      }
    }
    """

    struct LabelsBody: Decodable {
        struct Repository: Decodable { let labels: Connection? }
        struct Connection: Decodable { let nodes: [Node]; let pageInfo: PageInfo }
        struct Node: Decodable { let id: String; let name: String; let color: String; let description: String? }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        let repository: Repository?
    }

    struct Labelable: Decodable {
        struct Labels: Decodable { let nodes: [GQL.PRLabelNode] }
        let labels: Labels?
    }
    struct Payload: Decodable { let labelable: Labelable? }
    struct AddBody: Decodable { let addLabelsToLabelable: Payload? }
    struct RemoveBody: Decodable { let removeLabelsFromLabelable: Payload? }
}
