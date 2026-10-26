import Foundation
import Security
@testable import ShipKit
import Testing

private func rsaKey() throws -> SecKey {
    let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary
    return try #require(SecKeyCreateRandomKey(attributes, nil))
}

/// The PEM GitHub would hand out for `key`: PKCS#1, 64 characters a line.
private func pem(_ key: SecKey, lineEnding: String = "\n") throws -> String {
    let der = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
    let body = der.base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r\n", with: lineEnding)
    return ["-----BEGIN RSA PRIVATE KEY-----", body, "-----END RSA PRIVATE KEY-----", ""].joined(separator: lineEnding)
}

private func base64URLDecode(_ s: Substring) throws -> Data {
    var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    return try #require(Data(base64Encoded: b64))
}

private func verifies(_ jwt: String, with key: SecKey) throws -> Bool {
    let parts = jwt.split(separator: ".")
    let signed = Data("\(parts[0]).\(parts[1])".utf8)
    let publicKey = try #require(SecKeyCopyPublicKey(key))
    return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData,
                                 try base64URLDecode(parts[2]) as CFData, nil)
}

@Test func jwtHeaderClaimsAndSignature() throws {
    let key = try rsaKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let jwt = try GitHubApp(appID: 123456, key: AppKey(key)).jwt(now: now)
    let parts = jwt.split(separator: ".")
    #expect(parts.count == 3)
    #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))

    let header = try JSONSerialization.jsonObject(with: base64URLDecode(parts[0])) as? [String: String]
    #expect(header == ["alg": "RS256", "typ": "JWT"])
    let claims = try #require(try JSONSerialization.jsonObject(with: base64URLDecode(parts[1])) as? [String: Any])
    #expect(claims["iat"] as? Int == 1_800_000_000 - 60)
    #expect(claims["exp"] as? Int == 1_800_000_000 + 9 * 60)
    #expect(claims["iss"] as? String == "123456")
    #expect(try verifies(jwt, with: key))
}

@Test(arguments: ["\n", "\r\n"])
func readsGitHubsPEM(lineEnding: String) throws {
    let key = try rsaKey()
    let loaded = try AppKey(pem: pem(key, lineEnding: lineEnding))
    #expect(try verifies(GitHubApp(appID: 1, key: loaded).jwt(), with: key))
}

@Test func explainsKeysItCantUse() throws {
    func reason(_ pem: String) -> String? {
        do {
            _ = try AppKey(pem: pem)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    #expect(reason("ghs_notakey")?.contains("isn't a PEM file") == true)
    #expect(reason("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")?.contains("found -----BEGIN PRIVATE KEY-----") == true)
    #expect(reason("-----BEGIN RSA PRIVATE KEY-----\n!!!\n-----END RSA PRIVATE KEY-----")?.contains("damaged") == true)
    #expect(reason("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")?.contains("isn't an RSA private key") == true)
}

// MARK: - Installation tokens

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(minutes: Double) { lock.withLock { _now += minutes * 60 } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func next() -> Int { lock.withLock { _value += 1; return _value } }
}

/// Tokens that last an hour from the clock's time, numbered by how many have been made.
private func tokens(_ clock: TestClock, _ minted: Counter, delay: Duration = .zero) -> InstallationTokens {
    InstallationTokens(now: { clock.now }) {
        try await Task.sleep(for: delay)
        return InstallationToken(token: "ghs_\(minted.next())", expiresAt: clock.now + 60 * 60)
    }
}

@Test func refreshesWithTenMinutesLeft() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let minted = Counter()
    let source = tokens(clock, minted)

    #expect(try await source.token().token == "ghs_1")
    clock.advance(minutes: 49) // 11 minutes left
    #expect(try await source.token().token == "ghs_1")
    clock.advance(minutes: 1.5) // 9.5 minutes left
    #expect(try await source.token().token == "ghs_2")
    #expect(try await source.token().token == "ghs_2")
    #expect(minted.value == 2)
}

@Test func makesANewTokenAfterA401() async throws {
    let clock = TestClock(.now)
    let minted = Counter()
    let source = tokens(clock, minted)
    #expect(try await source.token().token == "ghs_1")
    await source.invalidate()
    #expect(try await source.token().token == "ghs_2")
}

@Test func concurrentCallersShareOneNewToken() async throws {
    let minted = Counter()
    let source = tokens(TestClock(.now), minted, delay: .milliseconds(50))
    let all = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<5 { group.addTask { try await source.token().token } }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(all) == ["ghs_1"])
    #expect(minted.value == 1)
}

// MARK: - Secrets stay out of errors

/// Answers every request to its own made-up host with a canned response, so tests can run in parallel.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, String)] = [:]

    static func api(status: Int, body: String) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { responses[host] = (status, body) }
        return URL(string: "https://\(host)")!
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { Self.responses[request.url?.host ?? ""] } ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func app(status: Int, body: String) throws -> GitHubApp {
    GitHubApp(appID: 1, key: AppKey(try rsaKey()), api: StubProtocol.api(status: status, body: body), session: StubProtocol.session)
}

@Test func mintsATokenFromGitHubsResponse() async throws {
    let body = #"{"token":"ghs_abc","expires_at":"2026-10-26T22:14:10Z","permissions":{"pull_requests":"read","metadata":"read"}}"#
    let token = try await app(status: 201, body: body).installationToken(7)
    #expect(token.token == "ghs_abc")
    #expect(token.expiresAt == Date(timeIntervalSince1970: 1_793_052_850))
    #expect(token.permissions == ["pull_requests": "read", "metadata": "read"])
}

@Test func tokenNeverAppearsInErrors() async throws {
    let secret = "ghs_s3cretS3cret"
    // GitHub sent a token, but in a shape we don't understand.
    let malformed = try app(status: 201, body: #"{"token":"\#(secret)","expires_at":"soon"}"#)
    // A failure whose body carries more than GitHub's message.
    let rejected = try app(status: 401, body: #"{"message":"Bad credentials","token":"\#(secret)"}"#)

    for app in [malformed, rejected] {
        do {
            _ = try await app.installationToken(7)
            Issue.record("expected an error")
        } catch {
            let text = "\(error.localizedDescription) \(error) \(String(reflecting: error))"
            #expect(!text.contains(secret))
            #expect(!text.contains("eyJ")) // nor the JWT
            #expect(text.contains("POST /app/installations/7/access_tokens"))
        }
    }

    do {
        _ = try await rejected.installationToken(7)
    } catch {
        #expect(error.localizedDescription == "GitHub returned HTTP 401 for POST /app/installations/7/access_tokens: Bad credentials")
    }

    let token = InstallationToken(token: secret, expiresAt: .now)
    #expect(!"\(token)".contains(secret))
    #expect(!String(reflecting: token).contains(secret))
}

@Test func flagsMissingAndWritePermissions() {
    var permissions = Dictionary(uniqueKeysWithValues: InstallationToken.wallPermissions.map { ($0, "read") })
    #expect(InstallationToken(token: "t", expiresAt: .now, permissions: permissions).missingPermissions.isEmpty)

    permissions["administration"] = nil
    permissions["contents"] = "write"
    permissions["issues"] = "write"
    let token = InstallationToken(token: "t", expiresAt: .now, permissions: permissions)
    #expect(token.missingPermissions == ["administration"])
    #expect(token.writePermissions == ["contents", "issues"])
}
