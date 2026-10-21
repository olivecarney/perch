# Architecture

[Documentation](README.md) · [Contributing](../CONTRIBUTING.md) · [HTTP API](api.md)

## Code map

| Path | Responsibility |
| --- | --- |
| `src/main.rs` | Startup, embedded assets, routes and collection mutations |
| `src/model.rs` | App fields, validation, ordering and persistence; Rust unit tests |
| `src/lib.rs` | Exposes the model module |
| `public/shell.html` | Dashboard and editor markup |
| `public/app.css` | Layout and greyscale styling |
| `public/app.js` | UI state, API requests, editing, uploads and drag/button ordering |
| `public/logos.mjs` | Browser favicon resolution |
| `tests/` | HTTP, logo, deployment and installer-dialog tests |
| `scripts/` | Native installation, updates, release helpers and Proxmox installer |
| `deploy/perch.service` | Managed Linux service |
| `.github/workflows/release.yml` | Linux validation, packaging and release publication |

## Server and browser

Perch uses Topcoat with only its serving and view features enabled. Tokio runs on a single thread. HTML, CSS, JavaScript, SVG icons and the font are compiled into the executable through Rust's include macros. Serving the binary does not require a source checkout or asset directory.

The browser loads the collection from `GET /api/apps` and sends save, delete and reorder actions to `POST /api/apps`. It updates its local list from each successful mutation response. There is no background polling, availability monitoring or cross-tab synchronisation.

The browser resolves favicons directly from service origins and processes uploaded images locally. The Rust server does not fetch service pages, proxy logos or resize images. Remote logos therefore depend on the browser's network access and certificate/content policies.

## State and persistence

Startup reads `PERCH_DATA`, parses the app array and validates each entry. A missing file means an empty collection; unreadable or malformed existing data fails startup. The app count is limited to 256.

A mutex protects the in-memory collection and serialises mutations. Each mutation clones the current list, applies and validates its change, serialises the result, writes and syncs a temporary file, then renames it over the collection. Memory is updated only after persistence succeeds. Run one process per data file; the mutex does not coordinate independent processes.

Array order is display order. Reordering requires an exact permutation of current IDs, rejecting missing, repeated or unknown IDs. Legacy description, category and favorite fields remain in the data model for compatibility, although the UI does not expose them.

## Deployment

Native builds default to loopback port 3000. Docker runs as UID/GID `10001:10001` with `/data/apps.json`. Packaged systemd installations run as `perch`, normally on port 80 with `/var/lib/perch/apps.json`.

The native updater verifies release checksums before stopping the service, replaces the executable atomically and attempts rollback if startup or the HTTP health check fails. It preserves the collection, environment file and service unit. See [Proxmox operations](proxmox.md) for details and limitations.

Perch has no authentication or TLS layer. Deployment access control belongs at the network or authenticated reverse proxy boundary.
