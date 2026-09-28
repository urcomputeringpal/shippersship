import Foundation

extension GitHubClient {
    /// Converts a PR to a draft, or marks a draft ready for review. Returns the PR's draft state afterwards.
    public func setDraft(_ draft: Bool, pullRequestID: String) async throws -> Bool {
        let body: DraftBody = try await graphQL(draft ? Self.convertToDraft : Self.markReady, variables: ["id": pullRequestID])
        guard let isDraft = (body.convertPullRequestToDraft ?? body.markPullRequestReadyForReview)?.pullRequest?.isDraft else {
            throw ClientError.graphQL(["GitHub didn't return the pull request"])
        }
        return isDraft
    }

    static let convertToDraft = """
    mutation ConvertToDraft($id: ID!) {
      convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } }
    }
    """

    static let markReady = """
    mutation MarkReady($id: ID!) {
      markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } }
    }
    """

    struct DraftBody: Decodable {
        struct Payload: Decodable {
            struct PR: Decodable { let isDraft: Bool }
            let pullRequest: PR?
        }
        let convertPullRequestToDraft: Payload?
        let markPullRequestReadyForReview: Payload?
    }
}
