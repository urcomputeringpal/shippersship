# Setting up Shippers Ship Wall

The wall signs in as a GitHub App that you create in your organization, not as a person. The App can only read. It has no webhook, and nobody signs in to it.

Setup takes about five minutes and needs an organization owner.

## 1. Create the App

Open this link, after replacing `ORG` with your organization's login in both places:

```text
https://github.com/organizations/ORG/settings/apps/new?name=Shippers%20Ship%20Wall%20(ORG)&description=Read-only%20office%20WIP%20wall&url=https://github.com/urcomputeringpal/shippersship&public=false&webhook_active=false&actions=read&administration=read&checks=read&contents=read&deployments=read&merge_queues=read&metadata=read&pull_requests=read&statuses=read&organization_self_hosted_runners=read
```

It fills in the whole form. Check these, then click **Create GitHub App** at the bottom:

- **GitHub App name** is filled in as "Shippers Ship Wall (ORG)". Names are unique across GitHub and can be at most 34 characters, so shorten it if GitHub objects, for example to "Shippers Ship Wall (acme)".
- **Webhook:** "Active" is unchecked.
- **Permissions** are all **Read-only**:

  | Permission | Kind | What the wall reads |
  | --- | --- | --- |
  | Actions | Repository | Workflow runs and jobs, for the runner strip |
  | Administration | Repository | Self-hosted runners registered on a repository instead of the organization. GitHub puts them under this permission, which also lets the App read the repository's settings. |
  | Checks | Repository | Check runs on each PR |
  | Commit statuses | Repository | Status contexts on each PR |
  | Contents | Repository | Commits on the default branch, for main's health |
  | Deployments | Repository | What's live in each environment |
  | Merge queues | Repository | Each PR's place in the merge queue |
  | Metadata | Repository | Repository names (GitHub requires this one) |
  | Pull requests | Repository | The PRs themselves, reviews and threads |
  | Self-hosted runners | Organization | Runner names, and whether each is busy |

- **Where can this GitHub App be installed?** is "Only on this account".

## 2. Generate a private key

The App's **General** page opens.

1. Note the **App ID** near the top.
2. Scroll to **Private keys** and click **Generate a private key**. Your browser downloads a `.pem` file.

## 3. Install it

1. In the sidebar, click **Install App**, then **Install** next to your organization.
2. Pick **All repositories**, or **Only select repositories** and choose them.
3. Click **Install**.

You can change the repositories later from the organization's **Settings → GitHub Apps → Configure**, and the wall picks up the change on its own.

## 4. Configure the wall

On the Mac that runs the wall, from a checkout of this repo (until releases include the wall):

```bash
swift run ShippersShipWall configure --app-id 123456 --key ~/Downloads/your-app.2026-10-26.private-key.pem
```

`configure` checks that the key belongs to the App, finds the App's installation, and saves:

- the key, to `~/Library/Application Support/Shippers Ship Wall/app-key.pem`, readable only by you (mode 0600)
- the App ID, the installation ID and the organization, to `config.json` next to it

Then delete the downloaded `.pem`. The wall only needs its own copy.

## 5. Check it

```bash
swift run ShippersShipWall status
```

`status` prints the App and its installation, how many repositories it covers, when the current token expires, the rate limit left, and where the key is stored. It never prints a token. It also warns if the App is missing a permission the wall needs, or has one that can write.

## Adding a permission later

If `status` says a permission is missing, for example on an App created before the wall needed it:

1. On the App's page, open **Permissions & events**, set the permission to **Read-only**, and click **Save changes**.
2. The organization has to accept the change. Open the organization's **Settings → GitHub Apps**, click **Configure** next to the App, and accept the new permissions. Until then, the App's tokens keep their old permissions.
3. Run `status` again.

## About the key

Anyone with the key can read everything the App can read, across every repository it's installed on, until you revoke the key.

- **It's a file,** not a Keychain item. Release builds are ad-hoc signed, and the Keychain would ask for permission again after each upgrade, with nobody at the wall to answer.
- **Any process running as the same macOS user can read it.** On a Mac whose self-hosted runner runs jobs as that user, so can those jobs.
- **To rotate it,** generate a new key on the App's page, run `configure` again with the new file, then delete the old key on GitHub.
- **If it leaks,** delete it on the App's page. The tokens it made stop working within an hour.
