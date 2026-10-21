# Installation and configuration

[Documentation](README.md) · [User guide](user-guide.md)

## Build and run

Install Rust 1.98 or newer with Cargo, then:

```sh
git clone https://github.com/olivecarney/perch.git
cd perch
cargo build --release --locked
./target/release/perch
```

Open `http://127.0.0.1:3000`. New installations start empty. Rust and Cargo are needed only to build; the binary embeds its assets and can be copied to a machine with the same OS and CPU architecture.

For the packaged Linux x86_64 release and managed service, follow the [Proxmox guide](proxmox.md). Release assets are available from [GitHub Releases](https://github.com/olivecarney/perch/releases).

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | Network interface to bind |
| `PORT` | `3000` | HTTP port |
| `PERCH_DATA` | `data/apps.json` | Writable app collection file |

For access from other devices on your trusted LAN:

```sh
HOST=0.0.0.0 PORT=3000 PERCH_DATA=/path/to/perch/apps.json ./target/release/perch
```

Replace the data path with a writable location. Relative paths are resolved from the process's working directory; use an absolute path when running Perch as a service. Missing directories are created on the first save. The process needs write access to the data directory because saves create a temporary file beside the collection before renaming it.

Use a non-privileged port such as 3000 for a manually launched binary. The packaged systemd service uses port 80 and grants the dedicated service user the capability needed to bind it.

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

Open `http://<docker-host>:3000`. The named volume keeps data when the container is replaced. Back it up before removing the volume; see [storage and recovery](operations.md).

## Network access

`HOST=127.0.0.1` permits connections from the local machine. `HOST=0.0.0.0` listens on all IPv4 interfaces; use the machine's LAN address in your browser. Check host and container firewall rules if another device cannot connect.

Perch provides neither authentication nor TLS. Restrict access to a trusted network or put it behind an authenticated HTTPS reverse proxy. Cross-origin browser write rejection does not prevent direct API access by someone who can reach the server.
