# Publishing releases

[Documentation](README.md) · [Contributing](../CONTRIBUTING.md)

For maintainers with permission to push tags and publish GitHub releases.

The workflow reads `rust-version` from `Cargo.toml` (currently 1.98), runs formatting,
Rust tests, Clippy, JavaScript tests and deployment tests, then builds with the
existing size-optimised release profile for `x86_64-unknown-linux-musl`. It rejects
binaries that need a dynamic loader or shared libraries, and runs the HTTP suite
with the exact Linux release binary outside the source tree. CI also installs the
packaged systemd service on its Ubuntu runner, checks HTTP port 80 and verifies
that a saved collection survives a service restart. Musl static linking
avoids a dependency on the build runner's glibc version.

Make the package version in `Cargo.toml` and
`Cargo.lock` match the intended release, commit, then push a matching version tag
(replace `X.Y.Z` with that version):

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

The workflow creates a draft, uploads all assets, then publishes it. Prerelease
tags remain prereleases and are not selected by `latest`. Pull requests, pushes
to `main` and manual runs build/test and upload Actions artifacts without publishing.
Release assets are:

- `perch-x86_64-unknown-linux-musl.tar.gz` (binary, native deployment scripts, unit,
  version marker and licenses; archive metadata and gzip timestamps normalised)
- `SHA256SUMS`

Review the workflow results before announcing a release. Linux CI checks do not
replace a real Proxmox installation test. Local tests cover application
behavior, archive verification, update/rollback and host input checks with external
service/Proxmox calls mocked; they do not establish production host compatibility.
