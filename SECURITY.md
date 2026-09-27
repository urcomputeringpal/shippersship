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
