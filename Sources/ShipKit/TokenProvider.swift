import Foundation
import Security

/// Finds a GitHub token: $GITHUB_TOKEN, then a token saved in the Keychain, then `gh auth token`.
public enum TokenProvider {
    public enum Source: String, Sendable {
        case environment = "GITHUB_TOKEN"
        case keychain = "saved token"
        case ghCLI = "gh CLI"
    }

    public static func resolve() async -> (token: String, source: Source)? {
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty {
            return (env, .environment)
        }
        if let saved = Keychain.read(), !saved.isEmpty {
            return (saved, .keychain)
        }
        if let gh = await ghToken() {
            return (gh, .ghCLI)
        }
        return nil
    }

    static func ghToken() async -> String? {
        // Apps launched from Finder don't inherit the shell PATH, so probe the usual install locations.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }.value
    }
}

public enum Keychain {
    static let service = "com.urcomputeringpal.shippersship"
    static let account = "github-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ token: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // Never leaves this Mac (not in backups restored elsewhere), and only readable while unlocked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
