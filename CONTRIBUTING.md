# Contributing to Perch

Perch is a small homelab app launcher with an embedded browser interface and a single JSON collection. Keep changes focused and preserve its simple deployment model.

## Local setup

You need Rust 1.98 or newer with Cargo. Python 3 runs integration and deployment checks; Node.js 18+ runs the dependency-free logo tests. Bash, ShellCheck and actionlint are needed for deployment/workflow checks. Linux terminal-dialog tests also need `whiptail`; they skip when it is unavailable.

```sh
git clone https://github.com/olivecarney/perch.git
cd perch
cargo build --locked
```

Run against a disposable collection so development does not change your normal dashboard:

```sh
PERCH_DATA=data/dev-apps.json cargo run
```

Open `http://127.0.0.1:3000` for local development. Installed Proxmox/systemd deployments use port 80 and are reached at `http://<server-ip>/` without a port suffix. There is no frontend package installation or bundler. Changes to `public/` require recompilation because assets are embedded.

## Find the right code

See [architecture](docs/architecture.md) for the code map and [HTTP API](docs/api.md) for data contracts. Installation and update behavior lives in `scripts/`, the systemd unit in `deploy/`, and release automation in `.github/workflows/release.yml`.

## Validate your changes

Run the relevant checks below. The release workflow runs Rust, browser-logic and deployment checks on Linux and exercises the packaged service. For application changes, build the binary before running HTTP tests:

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --release --locked
PERCH_BINARY=target/release/perch python3 tests/test_http.py
node --test tests/logos.test.mjs
```

For installer, updater or release changes, also run:

```sh
python3 tests/test_deployment.py
python3 tests/test_installer_tui.py
bash -n scripts/proxmox/install.sh scripts/install-native.sh scripts/perch-update scripts/release-common.sh
shellcheck -x scripts/proxmox/install.sh scripts/install-native.sh scripts/perch-update scripts/release-common.sh
actionlint
```

HTTP tests start disposable server processes and use temporary collections. Deployment tests mock external host/service commands. Terminal tests use real `whiptail` in a pseudo-terminal when available. These tests do not establish compatibility with a real Proxmox host; document any host validation separately.

For interface changes, check adding, editing, removing, logo selection, drag and button ordering, reload persistence, keyboard use and a narrow viewport against a disposable collection. Include screenshots for visible changes.

## Submit a change

1. Open an issue for bugs or substantial feature proposals, including expected and actual behavior.
2. Create a focused branch and implement the change. Add regression coverage where behavior changes and update the relevant guide.
3. Run the applicable checks and review your diff for credentials or private collection data.
4. Open a pull request explaining the problem, resulting behavior, validation and any limitations.

Preserve compatibility with existing collections, including hidden legacy fields. Keep persistence atomic and do not commit personal app data. New assets need appropriate licensing and attribution in [THIRD_PARTY.md](THIRD_PARTY.md). Contributions are covered by the project's [MIT license](LICENSE).

Maintainers can follow [publishing releases](docs/releases.md) after a change is ready to ship.
