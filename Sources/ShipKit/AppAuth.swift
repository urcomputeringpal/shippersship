import Foundation
import Security

public enum AppAuthError: LocalizedError, Equatable {
    case badKey(String)
    case signing
    /// Status, GitHub's `message`, and the request ("GET /app").
    case http(Int, String?, String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .badKey(why): "Can't use the App's private key: \(why)."
        case .signing: "Couldn't sign a JWT with the App's private key."
        case let .http(code, message, request): "GitHub returned HTTP \(code) for \(request)" + (message.map { ": \($0)" } ?? "")
        case let .unexpectedResponse(request): "GitHub sent an unexpected response to \(request)."
        }
    }
}

/// A GitHub App's private key. It signs JWTs, and nothing reads it back out.
public struct AppKey: @unchecked Sendable { // SecKey is immutable and safe to use from any thread.
    let secKey: SecKey

    init(_ secKey: SecKey) {
        self.secKey = secKey
    }

    /// Reads the PEM file GitHub downloads when you generate an App's private key ("BEGIN RSA PRIVATE KEY").
    public init(pem: String) throws {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }),
              let end = lines[begin...].firstIndex(where: { $0.hasPrefix("-----END ") }) else {
            throw AppAuthError.badKey("it isn't a PEM file")
        }
        guard lines[begin] == "-----BEGIN RSA PRIVATE KEY-----" else {
            throw AppAuthError.badKey("expected the RSA private key from the App's page, but found \(lines[begin])")
        }
        guard let der = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else {
            throw AppAuthError.badKey("its base64 is damaged")
        }
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        guard let key = SecKeyCreateWithData(der as CFData, attributes, nil),
              SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw AppAuthError.badKey("it isn't an RSA private key")
        }
        self.init(key)
    }

    func sign(_ data: Data) throws -> Data {
        guard let signature = SecKeyCreateSignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) else {
            throw AppAuthError.signing
        }
        return signature as Data
    }
}

/// Signs in as a GitHub App: JWTs for the App's own endpoints, and installation tokens for everything else.
public struct GitHubApp: Sendable {
    public let appID: Int
    let key: AppKey
    let rest: GitHubREST

    public init(appID: Int, key: AppKey, api: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared) {
        self.appID = appID
        self.key = key
        self.rest = GitHubREST(api: api, session: session)
    }

    /// An RS256 JWT for the App's own endpoints. GitHub allows at most 10 minutes, and `iat` is a minute early
    /// in case this Mac's clock runs ahead.
    public func jwt(now: Date = .now) throws -> String {
        let issued = Int(now.timeIntervalSince1970) - 60
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let claims = #"{"iat":\#(issued),"exp":\#(issued + 10 * 60),"iss":"\#(appID)"}"#
        let signingInput = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(Data(claims.utf8))
        return signingInput + "." + Self.base64URL(try key.sign(Data(signingInput.utf8)))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func app() async throws -> AppInfo {
        try await rest.send("/app", bearer: jwt())
    }

    public func installations() async throws -> [Installation] {
        try await rest.send("/app/installations", bearer: jwt())
    }

    public func installation(_ id: Int) async throws -> Installation {
        try await rest.send("/app/installations/\(id)", bearer: jwt())
    }

    /// A new installation token, good for an hour. `InstallationTokens` decides when to make one.
    public func installationToken(_ installationID: Int) async throws -> InstallationToken {
        try await rest.send("/app/installations/\(installationID)/access_tokens", method: "POST", bearer: jwt())
    }

    /// How many repositories the installation covers, with the first 100 names.
    public func repositories(token: InstallationToken) async throws -> InstallationRepositories {
        try await rest.send("/installation/repositories?per_page=100", bearer: token.token)
    }

    /// Checking the rate limit doesn't count against it.
    public func rateLimits(token: InstallationToken) async throws -> RateLimits {
        try await rest.send("/rate_limit", bearer: token.token)
    }
}

/// Keeps one installation token in memory, and makes a new one when less than 10 minutes are left
/// or after GitHub rejects it.
public actor InstallationTokens {
    public static let refreshMargin: TimeInterval = 10 * 60

    private let mint: @Sendable () async throws -> InstallationToken
    private let now: @Sendable () -> Date
    private var current: InstallationToken?
    private var minting: Task<InstallationToken, any Error>?

    public init(app: GitHubApp, installationID: Int) {
        self.init(now: { .now }) { try await app.installationToken(installationID) }
    }

    init(now: @escaping @Sendable () -> Date, mint: @escaping @Sendable () async throws -> InstallationToken) {
        self.now = now
        self.mint = mint
    }

    /// A token with at least 10 minutes left. Callers that arrive while one is being made share it.
    public func token() async throws -> InstallationToken {
        if let current, current.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return current }
        if let minting { return try await minting.value }
        let task = Task { try await mint() }
        minting = task
        defer { minting = nil }
        let fresh = try await task.value
        current = fresh
        return fresh
    }

    /// Forgets the current token. Call it when GitHub rejects the token with a 401.
    public func invalidate() {
        current = nil
    }
}

// MARK: - Wire format

public struct AppInfo: Decodable, Sendable {
    public let id: Int
    public let slug: String
    public let name: String
}

public struct Installation: Decodable, Sendable {
    public struct Account: Decodable, Sendable {
        public let login: String
    }

    public let id: Int
    public let account: Account
    /// "all" or "selected"
    public let repositorySelection: String

    enum CodingKeys: String, CodingKey {
        case id, account
        case repositorySelection = "repository_selection"
    }
}

/// Its `description` leaves the token out, so printing one by accident doesn't leak it.
public struct InstallationToken: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let expiresAt: Date
    /// What the token can do, like `["pull_requests": "read"]`.
    public let permissions: [String: String]

    init(token: String, expiresAt: Date, permissions: [String: String] = [:]) {
        self.token = token
        self.expiresAt = expiresAt
        self.permissions = permissions
    }

    enum CodingKeys: String, CodingKey {
        case token, permissions
        case expiresAt = "expires_at"
    }

    public var description: String { "InstallationToken(expires: \(expiresAt.formatted(.iso8601)))" }
    public var debugDescription: String { description }

    /// Everything the wall reads. Administration covers runners registered on a repository, not the organization.
    public static let wallPermissions = [
        "actions", "administration", "checks", "contents", "deployments", "merge_queues", "metadata",
        "organization_self_hosted_runners", "pull_requests", "statuses",
    ]

    /// Permissions the wall needs that the App doesn't have.
    public var missingPermissions: [String] {
        Self.wallPermissions.filter { permissions[$0] == nil }
    }

    /// Permissions the App has beyond reading. The wall never writes.
    public var writePermissions: [String] {
        permissions.filter { $0.value != "read" }.keys.sorted()
    }
}

public struct InstallationRepositories: Decodable, Sendable {
    public struct Repository: Decodable, Sendable {
        public let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }

    public let totalCount: Int
    public let repositories: [Repository]

    enum CodingKeys: String, CodingKey {
        case repositories
        case totalCount = "total_count"
    }
}

public struct RateLimits: Decodable, Sendable {
    public struct Limit: Decodable, Sendable {
        public let limit: Int
        public let remaining: Int
        /// Seconds since 1970.
        let reset: Int
        public var resetsAt: Date { Date(timeIntervalSince1970: TimeInterval(reset)) }
    }

    public struct Resources: Decodable, Sendable {
        public let core: Limit
        public let graphql: Limit
    }

    public let resources: Resources
}
