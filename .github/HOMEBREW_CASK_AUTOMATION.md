# Homebrew cask release automation

`update-homebrew-cask.yml` runs only when it is manually dispatched. At the
start of every run, it resolves the latest stable GitHub Release in
`Afcoo/ThruRNDIS`. It downloads that release's exact
`ThruRNDIS-<version>.dmg` asset, calculates its SHA-256 checksum, updates
`Casks/thrurndis.rb` in `Afcoo/homebrew-tap`, and opens a pull request from an
`automation/update-thrurndis-cask` branch. A later run updates the same branch
and open pull request to the then-latest release.

## Run the workflow

Upload the DMG to a stable GitHub Release first, then run **Update Homebrew
cask** from the repository's Actions page. It can also be started with GitHub
CLI:

```sh
gh workflow run update-homebrew-cask.yml --repo Afcoo/ThruRNDIS
```

If the cask on `homebrew-tap/main` already contains the latest version and
checksum, the workflow completes without creating a pull request and closes
any obsolete open pull request from the fixed automation branch.

## GitHub App setup

Create or reuse a GitHub App with these repository permissions:

- Contents: Read and write
- Pull requests: Read and write

Install the App for `Afcoo/homebrew-tap`. The App does not need access to the
source repository: its release asset is read with the source repository's
short-lived `GITHUB_TOKEN`, while the App installation token is scoped to
`Afcoo/homebrew-tap`.

Configure these Actions values in `Afcoo/ThruRNDIS`:

- Repository secret `HOMEBREW_TAP_APP_CLIENT_ID`: the GitHub App client ID
- Repository secret `HOMEBREW_TAP_APP_PRIVATE_KEY`: the complete PEM private
  key, including its BEGIN and END lines

The workflow requests an installation token limited to `homebrew-tap` and to
the two permissions above. The token is revoked automatically when the job
finishes.

## Release contract

- Stable release tags must start with `v` and contain numeric dot-separated
  components, for example `v0.2.0`.
- The release must contain exactly named asset
  `ThruRNDIS-<version>.dmg`.
- Drafts and prereleases are excluded by GitHub's latest-release API.

Concurrent manual runs are serialized. Each run updates the fixed automation
branch with `--force-with-lease` and creates or refreshes its open pull request
when the cask needs an update.
