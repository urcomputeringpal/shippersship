import Foundation

/// The few REST endpoints GraphQL doesn't cover: GitHub App auth, installations and rate limits.
struct GitHubREST: Sendable {
    let api: URL
    let session: URLSession

    init(api: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared) {
        self.api = api
        self.session = session
    }

    /// Sends a request with a bearer credential (a JWT or an installation token) and decodes the JSON response.
    ///
    /// Errors carry only the status and GitHub's own `message`, never the response body, which can hold a token.
    func send<T: Decodable>(_ path: String, method: String = "GET", bearer: String) async throws -> T {
        guard let url = URL(string: api.absoluteString + path) else { throw AppAuthError.unexpectedResponse(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ShippersShipWall", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw AppAuthError.http(status, message, "\(method) \(path)")
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AppAuthError.unexpectedResponse("\(method) \(path)")
        }
    }

    /// Types spell out their snake_case keys: `.convertFromSnakeCase` would also rename dictionary keys,
    /// like a token's `pull_requests` permission.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    struct ErrorBody: Decodable { let message: String }
}
