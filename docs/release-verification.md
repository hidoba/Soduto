# Verify the release

Starting with **Soduto 3.2.1 (37)**, GitHub Actions builds, tests, attests, and publishes the release. The release page shows **github-actions[bot]** as its publisher and links the exact source commit and workflow run. Publication waits for both the application checks and the separate Keychain/TLS job to pass.

The ZIP is copied directly from the signed CI package without repackaging. GitHub's signed build attestation binds its SHA-256 to the source repository, commit, and workflow. The release also includes an attested `build-info.json` and a `release-attestation.sigstore.json` bundle.

## Verify your download

Download the ZIP from the [latest release](https://github.com/hidoba/Soduto/releases/latest). With an up-to-date [GitHub CLI](https://cli.github.com/), run:

```sh
gh attestation verify Soduto-3.2.1-37-macos-universal.zip \
  --repo hidoba/Soduto \
  --signer-workflow hidoba/Soduto/.github/workflows/build.yml \
  --deny-self-hosted-runners
```

The result identifies the source commit and workflow. To require a particular commit, add `--source-digest` followed by its full SHA from the release notes. Each release includes a copyable command with this value filled in.

To verify using the attached attestation bundle, add:

```sh
--bundle release-attestation.sigstore.json
```

The same verification command works for `build-info.json` in place of the ZIP. A simple download integrity check is also available:

```sh
shasum -a 256 -c Soduto-3.2.1-37-macos-universal.zip.sha256
```

The attestation and checksum files stay attached to the release even after the temporary Actions artifacts expire. Verification links the released bytes to the stated source and workflow; it does not claim that an independent rebuild produces identical bytes or that the code has no bugs. This build attestation is separate from Apple Developer ID signing and notarization.

The website's latest commit date can include documentation changes after the app was built. Use the release's source commit when verifying a download. Earlier build 36 has checksum-based verification only; its [original verification guide](https://github.com/hidoba/Soduto/blob/a40ecf01783fce17b2edf6d5de50564048dca637/docs/release-verification.md) remains available.

## Publish a new build

Increase `CURRENT_PROJECT_VERSION` in the Xcode project, commit and push, then run:

```sh
gh workflow run build.yml --repo hidoba/Soduto \
  --ref codex/reliability-diagnostics \
  -f runner=macos-26 -f publish_release=true
```

The workflow derives a unique tag such as `v3.2.1-37` from the built app, verifies both attestations, creates the tag at the built commit, and publishes the assets with GitHub's built-in Actions token. It fails if that tag already exists, so an older release cannot be overwritten. No personal access token or signing secret is needed. Leave **Publish release** unchecked for a build that only uploads test artifacts.
