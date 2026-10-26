import Foundation

public enum WallConfigError: LocalizedError, Equatable {
    case missingConfig(String)
    case invalidConfig(String, String)
    case missingKey(String)
    case keyTooOpen(String, Int)

    public var errorDescription: String? {
        switch self {
        case let .missingConfig(path):
            "There's no wall config at \(path). Run `ShippersShipWall configure` first (see docs/wall-setup.md)."
        case let .invalidConfig(path, why):
            "\(path) is invalid: \(why)."
        case let .missingKey(path):
            "The App's private key isn't at \(path). Run `ShippersShipWall configure` again."
        case let .keyTooOpen(path, mode):
            "Other users can read \(path) (mode \(String(mode, radix: 8))). Run `chmod 600 '\(path)'`."
        }
    }
}

/// The wall's settings, saved in `~/Library/Application Support/Shippers Ship Wall/config.json`.
public struct WallConfig: Codable, Equatable, Sendable {
    /// The organization the App is installed on.
    public var org: String
    public var appID: Int
    public var installationID: Int
    /// The App's private key: a PEM file only this user can read (see `KeyFile`).
    public var keyFile: String

    public init(org: String, appID: Int, installationID: Int, keyFile: String) {
        self.org = org
        self.appID = appID
        self.installationID = installationID
        self.keyFile = keyFile
    }

    public static let directory = URL.applicationSupportDirectory.appending(path: "Shippers Ship Wall", directoryHint: .isDirectory)
    public static let defaultURL = directory.appending(path: "config.json")
    public static let defaultKeyURL = directory.appending(path: "app-key.pem")

    public static func load(from url: URL = defaultURL) throws -> WallConfig {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw WallConfigError.missingConfig(url.path)
        }
        let config: WallConfig
        do {
            config = try JSONDecoder().decode(WallConfig.self, from: data)
        } catch let error as DecodingError {
            throw WallConfigError.invalidConfig(url.path, describe(error))
        }
        if let problem = config.problem {
            throw WallConfigError.invalidConfig(url.path, problem)
        }
        return config
    }

    public func save(to url: URL = defaultURL) throws {
        try KeyFile.makePrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// What's wrong with the values, if anything.
    var problem: String? {
        if org.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/) == nil { return "\"org\" isn't a GitHub organization" }
        if appID <= 0 { return "\"appID\" must be a positive number" }
        if installationID <= 0 { return "\"installationID\" must be a positive number" }
        if keyFile.isEmpty { return "\"keyFile\" is empty" }
        return nil
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context, _ key: CodingKey? = nil) -> String {
            "\"" + (context.codingPath + [key].compactMap { $0 }).map(\.stringValue).joined(separator: ".") + "\""
        }
        return switch error {
        case let .keyNotFound(key, context): "\(path(context, key)) is missing"
        case let .typeMismatch(_, context), let .valueNotFound(_, context): "\(path(context)) has the wrong type"
        case .dataCorrupted: "it isn't valid JSON"
        @unknown default: "it couldn't be read"
        }
    }
}

/// The App's private key, kept as a PEM file only this user can read.
///
/// Not the Keychain: release builds are ad-hoc signed, so each upgrade looks like a different app to the Keychain,
/// which then asks for a password that nobody at the wall can type. (The data protection keychain refuses
/// ad-hoc signed apps outright.)
public enum KeyFile {
    /// Writes the key with mode 0600, into a directory only this user can enter, replacing any key already there.
    public static func write(_ pem: String, to url: URL) throws {
        try makePrivateDirectory(url.deletingLastPathComponent())
        // Create the file with its final mode, so the key is never readable by anyone else, even briefly.
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(pem.utf8))
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Reads the key, refusing a file that other users could read.
    public static func read(_ url: URL) throws -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let data = FileManager.default.contents(atPath: url.path) else {
            throw WallConfigError.missingKey(url.path)
        }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else { throw WallConfigError.keyTooOpen(url.path, mode) }
        return String(decoding: data, as: UTF8.self)
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
