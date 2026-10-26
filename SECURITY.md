# Security

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/urcomputeringpal/shippersship/security/advisories/new)
rather than in a public issue.

## How Shippers Ship handles your data

- **Token:** read from `$GITHUB_TOKEN`, from the Keychain (a token you pasted into Settings, stored
  this-device-only), or from `gh auth token`. It's sent only to `api.github.com` in the `Authorization` header,
  and never written to disk or logs by the app.
- **Network:** the app talks only to the GitHub GraphQL API. There's no telemetry.
- **Writes:** the only change the app makes on GitHub is adding or removing labels, and only when you ask it to.
  Labels can trigger workflows in some repos (e.g. `deploy:*` labels), so the picker changes nothing until you
  press ⏎ or click.
- **Links:** check, status and deployment URLs come from third parties. Only `http(s)` links are ever opened.

## How Shippers Ship Wall handles its key

The wall signs in as a read-only GitHub App (see [docs/wall-setup.md](docs/wall-setup.md)).

- **Private key:** a file at `~/Library/Application Support/Shippers Ship Wall/app-key.pem`, mode 0600, in a directory
  only its user can enter. The wall refuses to use it if other users can read it.
- **Why not the Keychain:** release builds are ad-hoc signed, so they can't use the Keychain unattended. The data
  protection keychain refuses them, and the login keychain asks for a password after every upgrade, with nobody at the
  wall to type it.
- **Who can read it:** any process running as the wall's macOS user. On a Mac where a self-hosted runner runs jobs as
  that user, those jobs can read it too.
- **Tokens:** installation tokens last an hour, are kept in memory only, and are sent only to `api.github.com`. They
  never appear in logs, errors, or `status`'s output.
- **Permissions:** every permission is read-only. `status` warns if the App can write anything.
- **Revoking:** delete the key on the App's page. Tokens it already made stop working within an hour.
