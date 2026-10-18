# Perch

A minimal homelab dashboard built with Rust and [Topcoat](https://github.com/tokio-rs/topcoat). Your apps, their logos, and nothing in the way.

![Perch dashboard](docs/assets/perch.png)

*Preview with example services. New installations start empty.*

## Small by design

- **One binary.** HTML, CSS, JavaScript, icons, and JetBrains Mono are embedded. No Node runtime, frontend build step, database, or font CDN.
- **Your apps, your order.** Add a name and URL or IP address. Use the pencil to edit, drag tiles, or move them with keyboard-accessible buttons. Order persists across restarts.
- **Automatic logos.** Perch looks for the service's favicon. Prefer something else? Choose a bundled icon, paste an image URL, or upload an image.
- **A quiet interface.** Industrial greyscale styling, monospace type, and the Perch bird. No categories, favorites, metrics, or background polling.
- **A single data file.** App links and order live in a local JSON file. No account or external service required.

Topcoat's default features are disabled; only serving and rendering support are enabled. The server uses a single-thread Tokio runtime. The release binary is approximately **1.2 MiB on the development Mac**; sizes and memory use vary by platform and workload.

## Quick start

Build with **Rust 1.98 or newer**:

```sh
git clone https://github.com/olivecarney/perch.git
cd perch
cargo build --release --locked
./target/release/perch
```

Open **http://127.0.0.1:3000** and select **Add app**.

Rust and Cargo are only required to build. The resulting binary runs without the source tree or `public/` directory. Build for the OS and CPU architecture of your homelab machine.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | Network interface to bind |
| `PORT` | `3000` | HTTP port |
| `PERCH_DATA` | `data/apps.json` | Writable app collection file |

For access from other devices on your trusted LAN:

```sh
HOST=0.0.0.0 PORT=3000 PERCH_DATA=/var/lib/perch/apps.json ./target/release/perch
```

Give the process write access to the data directory. Relative paths are resolved from the working directory. The directory is created on the first save.

**Perch has no authentication.** Anyone who can reach it can change its shortcuts. Keep it on a trusted private network or behind an authenticated reverse proxy. Cross-origin browser writes are rejected by Topcoat's origin policy.

## Using Perch

Select **Add app**, enter a name and an HTTP(S) URL or IP address, and save. Addresses without a scheme receive `http://`. Ports and paths are supported, such as `192.168.1.10:8096` or `https://nas.local/files/`.

Select the **pencil** to edit or reorder. Drag a tile by its handle, or use its left/right buttons. Select the **checkmark** when finished. In editing mode, select a tile or its menu to change or remove it.

The collapsed **Logo** row contains optional overrides. PNG, JPEG, and WebP uploads are resized to at most 128 × 128 pixels. The entire interface, including service logos, is displayed in greyscale.

## How logos work

Your browser tries a favicon under the app's path, then `/favicon.ico`, `/favicon.svg`, and `/apple-touch-icon.png` on the service's own origin. Ports are preserved. Requests send no referrer and use a 2.2-second limit per candidate. Images resolve only as tiles approach the viewport, and results are reused for the lifetime of the page.

The Rust server does not fetch or proxy services. There is no third-party favicon service, availability monitoring, or recurring discovery. A bundled or generic server icon appears while resolving and remains if all candidates fail.

Automatic resolution is best effort. Services with icons declared only through HTML metadata, authentication requirements, untrusted certificates, or mixed-content restrictions may need a direct image URL or uploaded logo. Browsers may log failed favicon candidates before the next one succeeds.

## Storage and backups

Back up the file at `PERCH_DATA`. To restore it, stop Perch, copy the backup into place, and restart.

Saves write a synced temporary file and atomically rename it into place. Failed writes leave the in-memory collection intact. An unreadable or malformed existing collection stops startup rather than replacing it. Reordering validates the complete app list before saving.

Run **one Perch process per data file**. Other browser tabs see changes after reloading; concurrent edits use last-write-wins semantics. Up to 256 apps are supported, with names limited to 80 characters and stored logos to 48 KB. Older category, favorite, and description fields are retained for compatibility but have no interface or ordering effect.

The default data directory is ignored by Git. If you set `PERCH_DATA` elsewhere inside the checkout, add that location to `.gitignore` before committing.

## Docker

An optional multistage build is included:

```sh
docker build -t perch .
docker run -d \
  --name perch \
  --restart unless-stopped \
  -p 3000:3000 \
  -v perch-data:/data \
  perch
```

The container runs as UID/GID `10001:10001` and stores its collection at `/data/apps.json`. Bind-mounted directories must be writable by that user. The Docker recipe has not yet been validated in this project; the native release build is tested.

## Proxmox VE LXC

**Release prerequisite:** at the time this installer was added, this repository had
no published releases. The command below becomes usable after these files reach
`main` and the first version tag finishes the **Check and release** workflow.
Until then, it exits before creating a container. See [Releases](https://github.com/olivecarney/perch/releases).

Run this one command in an interactive **Proxmox host shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/olivecarney/perch/main/scripts/proxmox/install.sh)"
```

This executes code from this repository as host root. Review
[the installer](scripts/proxmox/install.sh) first; you can download and inspect it
before running `bash install.sh`. The installer is original Perch code, inspired by
the Community Scripts installation experience, with no dependency on its framework.

The installer creates an **unprivileged Debian 13 amd64 container** and installs a
precompiled, statically linked x86_64 Linux binary. Rust, Cargo, Node.js, Docker,
source code and external frontend files are not needed inside the LXC. Curl and
CA certificates are installed for updates. ARM64 release assets are not yet provided.

Use a Proxmox VE host that supports Debian 13 standard templates (target: PVE 9),
a working Linux bridge such as `vmbr0`, outbound DNS and HTTPS access, and active
storage supporting `rootdir` and `vztmpl` content. The template storage and root
disk storage may be different. Containers also need access to Debian APT mirrors.
The script downloads the newest Debian 13 standard amd64 template in the PVE
catalogue if it is not already present on the chosen template storage.

| Setting | Default |
| --- | --- |
| CT ID | Next unused cluster-wide ID |
| Hostname / bridge | `perch` / `vmbr0` |
| IPv4 / DNS | DHCP / inherit host DNS |
| CPU | 1 core |
| RAM / swap | 256 MiB / 256 MiB |
| Root disk | 2 GiB |
| Port | `3000` |
| Container | Unprivileged; starts at host boot |

Every setting above is prompted, including storage, release version and a static
IPv4 address/prefix, gateway and space-separated IPv4 DNS servers. IPv6 provisioning
is not currently supported. Ports must be 1024–65535. Existing CT and VM IDs are
always refused; the installer never deletes containers. You confirm the settings
before creation. A failed installation retains any newly created CT for diagnosis.

These are conservative starting defaults, **not measured Proxmox minimums**. The
single-thread Rust service has no server-side image processing, but Debian, APT,
logs and app data also need resources. Maximum supported inline logos can consume
about 12 MB of JSON before in-memory overhead. Increase RAM/disk for your workload;
the default footprint and installation peak memory still need real-host validation.

After installation, use `pct exec 123 -- hostname -I` to find the address, then open
`http://<container-ip>:3000` (replace `123` throughout with your CT ID).

### Native service configuration

The binary is `/usr/local/bin/perch`, running as the dedicated `perch` system user.
Data lives at **`/var/lib/perch/apps.json`**, owned by `perch:perch`, with directory
mode `0750` and file mode `0640`. The directory stays writable for atomic saves.

`/etc/default/perch` contains:

```ini
HOST=0.0.0.0
PORT=3000
PERCH_DATA=/var/lib/perch/apps.json
```

For a custom port, edit that file inside the CT and run `systemctl restart perch`.
Keep `HOST` reachable over loopback for update health checks and keep `PERCH_DATA`
at the managed path. The systemd service restarts on failure, drops capabilities,
blocks privilege escalation and makes the filesystem read-only except for the
state directory and private temporary storage. Local overrides belong in
`systemctl edit perch`.

**There is no built-in authentication or TLS.** Anyone with network access can
read and modify your shortcuts. Do not forward this port to the internet. Restrict
access with your network/firewall or use an authenticated HTTPS reverse proxy.
An unprivileged LXC and systemd hardening do not replace access control.
The installer enables `nesting=1` because Proxmox requires it for systemd service
isolation. This also exposes host procfs/sysfs contents to the guest, as described
in the [Proxmox container configuration documentation](https://raw.githubusercontent.com/proxmox/pve-docs/master/generated/pct.conf.5-opts.adoc).

### Updates and backups

From the Proxmox host:

```bash
pct exec 123 -- perch-update
```

Or run `perch-update` as root inside the CT. To choose a published version:

```bash
pct exec 123 -- perch-update v0.1.1
```

The updater resolves the latest stable GitHub release once, downloads its x86_64
archive and SHA-256 manifest, and verifies the checksum before stopping Perch.
The replacement uses an atomic rename on the same filesystem. Startup and an HTTP
check against `/api/apps` must succeed; otherwise the previous binary is restored
and restarted. Interrupted updates also attempt rollback (except untrappable
power loss or `SIGKILL`). A lock prevents overlapping native installs/updates.
The installed version is in `/usr/local/lib/perch/VERSION`.

Updates replace **only the executable and version marker**. They never write,
delete or migrate `apps.json`, and preserve your service settings. Back up the
collection before updates; a future release with a data format change may need
manual compatibility checks. Service/updater changes in future releases may also
require a separately documented maintenance step. Checksums detect corrupted
transfers; they rely on the integrity of the GitHub repository and release account,
and are not independent signatures.

To copy your collection to the host:

```bash
pct pull 123 /var/lib/perch/apps.json ./perch-apps.json
```

To restore: stop the service, copy the backup into place, ensure `perch:perch`
ownership and `0640` permissions, then start the service. Keep the existing
container/data intact if an old binary cannot read a newer file.

### Troubleshooting and uninstall

From the Proxmox host:

```bash
pct status 123
pct config 123
pct exec 123 -- systemctl status perch --no-pager
pct exec 123 -- journalctl -u perch -n 100 --no-pager
pct exec 123 -- cat /usr/local/lib/perch/VERSION
pct exec 123 -- curl -f http://127.0.0.1:3000/api/apps
```

For unreachable containers, check DHCP leases or static IP/gateway, DNS, the bridge
and PVE firewall rules. For a missing asset/404, check that the release workflow
finished and both the archive and `SHA256SUMS` are published. For a checksum
failure, retry and investigate the release; do not bypass verification. For
startup failures, check logs and data permissions. Malformed existing JSON stops
Perch rather than overwriting the collection. A rollback failure reports the
retained previous-binary path for manual recovery.

If installation fails after CT creation, inspect the retained CT before making
changes. It may be partially configured. Choose a new ID for another attempt, or
explicitly remove the failed CT after checking it contains no needed data.

To remove **the entire container and all its data**, first copy your backup off
it, verify the CT ID, and then explicitly run:

```bash
pct stop 123
pct destroy 123 --purge
```

To remove only Perch while keeping the CT and collection, run inside the CT:

```bash
systemctl disable --now perch
rm -f /etc/systemd/system/perch.service /etc/default/perch
rm -f /usr/local/bin/perch /usr/local/sbin/perch-update
rm -rf /usr/local/lib/perch
systemctl daemon-reload
```

This leaves `/var/lib/perch/apps.json` and its system user in place.

### Publishing a release (maintainers)

The workflow reads `rust-version` from `Cargo.toml` (currently 1.98), runs formatting,
Rust tests, Clippy, JavaScript tests and deployment tests, then builds with the
existing size-optimised release profile for `x86_64-unknown-linux-musl`. It rejects
binaries that need a dynamic loader or shared libraries, and runs the HTTP suite
with the exact Linux release binary outside the source tree. Musl static linking
avoids a dependency on the build runner's glibc version.

After merging the workflow, make the package version in `Cargo.toml` and
`Cargo.lock` match the intended release, commit, then push a matching version tag:

```bash
git tag v0.1.1
git push origin v0.1.1
```

The workflow creates a draft, uploads all assets, then publishes it. Prerelease
tags remain prereleases and are not selected by `latest`. Pull requests, pushes
to `main` and manual runs build/test and upload Actions artifacts without publishing.
Release assets are:

- `perch-x86_64-unknown-linux-musl.tar.gz` (binary, native deployment scripts, unit,
  version marker and licenses; archive metadata and gzip timestamps normalised)
- `SHA256SUMS`

The Linux build/packaging and systemd/LXC lifecycle must still be validated by the
first CI run and a real Proxmox installation. Local tests cover application
behavior, archive verification, update/rollback and host input checks with external
service/Proxmox calls mocked; they do not establish production host compatibility.

## Development

```sh
cargo run
```

Embedded asset changes require recompilation. There is no JavaScript bundler or package installation step.

Run the checks:

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo build --release --locked
PERCH_BINARY=target/release/perch python3 tests/test_http.py
node --test tests/logos.test.mjs
python3 tests/test_deployment.py
bash -n scripts/proxmox/install.sh scripts/install-native.sh scripts/perch-update scripts/release-common.sh
shellcheck -x scripts/proxmox/install.sh scripts/install-native.sh scripts/perch-update scripts/release-common.sh
actionlint
```

Python 3 is needed for HTTP integration tests, and Node.js 18+ for the logo tests. Neither is needed to run Perch. HTTP tests use disposable server processes and temporary collections, leaving your apps untouched.

## License and attribution

Perch is [MIT licensed](LICENSE). Service icons are from [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons), and the locally bundled [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) font uses the SIL Open Font License. See [THIRD_PARTY.md](THIRD_PARTY.md) and the included asset licenses. Product names and marks belong to their respective owners.
