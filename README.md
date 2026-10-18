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
```

Python 3 is needed for HTTP integration tests, and Node.js 18+ for the logo tests. Neither is needed to run Perch. HTTP tests use disposable server processes and temporary collections, leaving your apps untouched.

## License and attribution

Perch is [MIT licensed](LICENSE). Service icons are from [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons), and the locally bundled [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) font uses the SIL Open Font License. See [THIRD_PARTY.md](THIRD_PARTY.md) and the included asset licenses. Product names and marks belong to their respective owners.
