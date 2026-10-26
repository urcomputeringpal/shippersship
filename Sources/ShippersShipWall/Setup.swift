import Foundation
import ShipKit

enum Setup {
    /// Checks the key against GitHub, finds the App's installation, then saves the key and the config.
    static func configure(_ options: Options) async throws {
        guard let appID = try options.id("--app-id"), let keyPath = options["--key"] else {
            throw UsageError("configure needs --app-id and --key.\n\n\(usage)")
        }
        let keyURL = URL(filePath: (keyPath as NSString).expandingTildeInPath)
        guard let data = FileManager.default.contents(atPath: keyURL.path) else {
            throw UsageError("Can't read \(keyPath).")
        }
        let pem = String(decoding: data, as: UTF8.self)
        let app = GitHubApp(appID: appID, key: try AppKey(pem: pem))

        let info: AppInfo
        do {
            info = try await app.app()
        } catch AppAuthError.http(401, let message, _) {
            throw UsageError("GitHub rejected this key for App \(appID)" + (message.map { " (\($0))" } ?? "")
                + ". Check the App ID on the App's page, and that the key is still listed under Private keys.")
        } catch AppAuthError.http(404, _, _) {
            throw UsageError("There's no GitHub App with ID \(appID). The App ID is near the top of the App's General page.")
        }
        let installation = try await installation(of: app, info, id: options.id("--installation-id"))

        let config = WallConfig(org: installation.account.login, appID: appID, installationID: installation.id,
                                keyFile: WallConfig.defaultKeyURL.path)
        try KeyFile.write(pem, to: WallConfig.defaultKeyURL)
        try config.save()
        print("Saved \(WallConfig.defaultURL.path)")
        print("Saved the key to \(config.keyFile), readable only by \(NSUserName()).")
        if keyURL.standardizedFileURL.path != WallConfig.defaultKeyURL.standardizedFileURL.path {
            print("You can delete \(keyPath) now.")
        }
        print()
        try await status(config)
    }

    private static func installation(of app: GitHubApp, _ info: AppInfo, id: Int?) async throws -> Installation {
        if let id {
            do {
                return try await app.installation(id)
            } catch AppAuthError.http(404, _, _) {
                throw UsageError("\(info.name) has no installation \(id).")
            }
        }
        let all = try await app.installations()
        switch all.count {
        case 0:
            throw UsageError("\(info.name) isn't installed anywhere yet. Install it from "
                + "https://github.com/apps/\(info.slug)/installations/new, then run configure again.")
        case 1:
            return all[0]
        default:
            let list = all.map { "\($0.account.login) (\($0.id))" }.joined(separator: ", ")
            throw UsageError("\(info.name) is installed on \(list). Pass --installation-id to pick one.")
        }
    }

    /// Everything about the wall's sign-in, except the token itself.
    static func status(_ config: WallConfig) async throws {
        let app = GitHubApp(appID: config.appID, key: try AppKey(pem: KeyFile.read(URL(filePath: config.keyFile))))
        async let info = app.app()
        async let installation = app.installation(config.installationID)
        let token = try await app.installationToken(config.installationID)
        async let repos = app.repositories(token: token)
        async let limits = app.rateLimits(token: token)

        let (i, inst, r, l) = try await (info, installation, repos, limits)
        let names = r.repositories.map(\.fullName).sorted()
        let shown = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? ", and \(r.totalCount - 5) more" : "")
        let readOnly = token.permissions.filter { $0.value == "read" }.keys.sorted()
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }

        row("App", "\(i.name) (\(i.slug), ID \(i.id))")
        row("Installation", "\(inst.id) on \(inst.account.login), \(inst.repositorySelection) repositories")
        row("Repositories", "\(r.totalCount)" + (shown.isEmpty ? "" : ": \(shown)"))
        row("Token", "expires at \(time(token.expiresAt)) (\(token.expiresAt.formatted(.relative(presentation: .named))))")
        row("Permissions", "read " + readOnly.joined(separator: ", "))
        if !token.missingPermissions.isEmpty {
            let missing = token.missingPermissions
            row("", "⚠ missing \(missing.joined(separator: ", ")). Add \(missing.count == 1 ? "it" : "them") as Read-only on the App's page, "
                + "then accept the change on its installation (see docs/wall-setup.md).")
        }
        if !token.writePermissions.isEmpty {
            row("", "⚠ can also write \(token.writePermissions.joined(separator: ", ")). "
                + "The wall only reads: set these to Read-only on the App's page.")
        }
        row("Rate limit", "REST \(l.resources.core.remaining) of \(l.resources.core.limit) left, "
            + "GraphQL \(l.resources.graphql.remaining) of \(l.resources.graphql.limit), "
            + "resetting by \(time(max(l.resources.core.resetsAt, l.resources.graphql.resetsAt)))")
        row("Key", "file at \(config.keyFile), readable only by \(NSUserName())")
    }

    private static func row(_ label: String, _ value: String) {
        print(label.padding(toLength: 14, withPad: " ", startingAt: 0) + value)
    }
}
