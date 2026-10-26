import Foundation
import ShipKit

let usage = """
Usage: ShippersShipWall <command> [options]

Commands:
  configure --app-id <id> --key <file.pem> [--installation-id <id>]
                Save a GitHub App's ID and private key. See docs/wall-setup.md.
  status        Show the App, its installation, its token and rate limit, and where the key is.
  help          Show this help.
"""

@main
enum WallApp {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "help" : args.removeFirst()
        do {
            switch command {
            case "configure": try await Setup.configure(Options(args, allowed: ["--app-id", "--key", "--installation-id"]))
            case "status": try await Setup.status(WallConfig.load())
            case "help", "--help", "-h": print(usage)
            default: throw UsageError("Unknown command \"\(command)\".\n\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct UsageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// `--name value` and `--name=value` options.
struct Options {
    private var values: [String: String] = [:]

    init(_ args: [String], allowed: Set<String>) throws {
        var rest = args[...]
        while let arg = rest.popFirst() {
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first, allowed.contains(name) else {
                throw UsageError("Unexpected \"\(arg)\".\n\n\(usage)")
            }
            guard let value = parts.count == 2 ? parts[1] : rest.popFirst() else {
                throw UsageError("\(name) needs a value.")
            }
            values[name] = value
        }
    }

    subscript(name: String) -> String? { values[name] }

    func id(_ name: String) throws -> Int? {
        guard let value = values[name] else { return nil }
        guard let id = Int(value), id > 0 else { throw UsageError("\(name) must be a number, like 123456.") }
        return id
    }
}
