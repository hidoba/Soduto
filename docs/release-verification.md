# Verify the release

Soduto 3.2.1 (build 36) was built and packaged in GitHub Actions. The published ZIP is the original workflow output, renamed without changing its contents. Its SHA-256 matches both the CI archive and the hash recorded in the packaging log.

- [Source commit: `472beae`](https://github.com/hidoba/Soduto/commit/472beae289c38541c14b2f46b25a32ed3b0823a9)
- [Build workflow at that commit](https://github.com/hidoba/Soduto/blob/472beae289c38541c14b2f46b25a32ed3b0823a9/.github/workflows/build.yml)
- [Successful build, tests, packaging log, and artifacts](https://github.com/hidoba/Soduto/actions/runs/40003601222)
- [Release download](https://github.com/hidoba/Soduto/releases/tag/v3.2.1)

## Compare the download with the CI output

Download `Soduto-3.2.1-36-macos-universal.zip` from the release. With an authenticated GitHub CLI, download the original CI artifact into a new directory:

```sh
gh run download 40003601222 --repo hidoba/Soduto \
  --name soduto-build-472beae289c38541c14b2f46b25a32ed3b0823a9 \
  --dir ci-build-36
shasum -a 256 ci-build-36/Soduto-development.zip \
  Soduto-3.2.1-36-macos-universal.zip
```

Both files should have this SHA-256:

```text
796b1d7bfdaf136ac7a4b196fc46b4459fa7fb5853684b8c2c4afa68ecd4e10f
```

You can also find this hash in the build's **Seal app bundle and package development build** step and in `packaging.log` in its build-log artifact. Compare the inner `Soduto-development.zip` file; GitHub's artifact wrapper has its own, different digest.

Artifacts, including the downloadable log bundles, are retained for 14 days; this build's artifacts expire on 6 November 2026. After expiry, the run's online packaging log remains useful while GitHub retains it, but the artifact download command will no longer work.

This comparison links the released bytes to the workflow output at the stated commit. It is not a claim that a separate rebuild will produce identical bytes. The website's latest commit date may include documentation changes made after the app was built; use the release's source commit when verifying a build.
