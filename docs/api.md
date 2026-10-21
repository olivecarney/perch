# HTTP API

[Documentation](README.md) · [Architecture](architecture.md)

The dashboard and API share the same origin. Examples run on the installed Proxmox/systemd server, which uses HTTP port 80 (`http://127.0.0.1`, with no port suffix). From another machine, replace `127.0.0.1` with the dashboard's IP or hostname. For a local development build, use `http://127.0.0.1:3000` instead.

There is no authentication. Anyone who can reach the server can read and change the collection. Browser cross-origin writes are rejected, but that is not access control for scripts or other clients.

## Read the collection

```sh
curl --fail http://127.0.0.1/api/apps
```

`GET /api/apps` returns a JSON array in display order, or `[]` for an empty collection. An entry looks like:

```json
{
  "id": 1,
  "name": "NAS",
  "address": "http://nas.local/",
  "description": "",
  "category": "Utilities",
  "logo": "auto",
  "favorite": false
}
```

## Create an app

```sh
curl --fail-with-body http://127.0.0.1/api/apps \
  -H 'Content-Type: application/json' \
  --data '{"action":"save","app":{"id":0,"name":"NAS","address":"nas.local","logo":"auto"}}'
```

Use `id: 0` to create an app. The server assigns an ID and appends it to the list. Successful mutations return the complete updated JSON array with HTTP 200.

## Update an app

Send `{"action":"save","app":{...}}` with an existing nonzero ID and the complete desired app object. This replaces the entry; it is not a partial update. Fetch the current object first and preserve hidden legacy fields if you do not intend to change them. Omitted optional fields take their defaults.

## Delete or reorder

Send either body to `POST /api/apps` with `Content-Type: application/json`:

```json
{"action":"delete","id":1}
```

```json
{"action":"reorder","ids":[2,1]}
```

Deletion removes the shortcut. Reordering must supply every current ID exactly once. The example assumes the collection contains only IDs 1 and 2. Reload the list if another client has added or removed an app.

## App fields and limits

| Field | Rules and default |
| --- | --- |
| `id` | Required unsigned 64-bit integer; zero creates, an existing nonzero ID updates |
| `name` | Required; trimmed, 1–80 characters |
| `address` | Required; input at most 2,048 bytes; HTTP(S) URL without embedded credentials; missing scheme becomes `http://` |
| `logo` | Defaults to `auto`; bundled name, HTTP(S) image URL without embedded credentials, or supported image data URL; at most 48,000 bytes |
| `description` | Legacy field; defaults to empty; trimmed, at most 160 characters |
| `category` | Legacy field; defaults to `Utilities`; trimmed, 1–40 characters |
| `favorite` | Legacy boolean; defaults to `false` |

Bundled logo values are `server`, `jellyfin`, `proxmox`, `home-assistant`, `pi-hole`, `immich`, `truenas`, `portainer` and `grafana`. Inline logos use base64 PNG, JPEG or WebP data URLs. The UI resizes uploads; API clients must supply a suitably small image themselves.

The collection holds at most 256 apps. Mutation request bodies are limited to 64,000 bytes.

## Errors and concurrency

Invalid JSON, fields and reorder lists return HTTP 400. Updating or deleting an unknown ID returns HTTP 404. Persistence failures return an error without committing the proposed in-memory change. Error responses are not guaranteed to be JSON; check status before decoding a response as an app array.

There is no revision token or conditional update. Concurrent saves use last-write-wins semantics. Fetch the current list before constructing updates and use a single Perch process for each data file.
