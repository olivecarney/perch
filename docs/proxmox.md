# Install and manage Perch on Proxmox VE

[Documentation](README.md) · [Other installation methods](installation.md)

Precompiled Linux releases are available from [Releases](https://github.com/olivecarney/perch/releases).
The installer verifies the selected release before creating a container.

Run this one command in an interactive **Proxmox host shell as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/olivecarney/perch/main/scripts/proxmox/install.sh)"
```

This executes code from this repository as host root. Review
[the installer](../scripts/proxmox/install.sh) first; you can download and inspect it
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
| RAM / swap | 512 MiB / 256 MiB (256 MiB RAM available in Advanced) |
| Root disk | 2 GiB |
| Port | `80` (standard HTTP; no port suffix needed) |
| Container | Unprivileged; starts at host boot |

### Default and Advanced setup

On a normal Proxmox terminal the installer uses `whiptail` dialogs with arrow-key
navigation. A small terminal or host without `whiptail` gets a plain-text fallback;
no UI packages or external installer framework are downloaded onto the host.

- **Default Install** uses the table above, selects an unused cluster-wide ID and
  prefers `vmbr0`. If multiple eligible storage pools exist, you select the disk
  and template storage. A summary requires confirmation before creation.
- **Advanced Install** walks through every supported setting, validates each
  answer and lets you go Back without losing earlier answers. Back from the first
  step returns to the mode menu. Cancel/Exit there creates nothing. In the text
  fallback, use `:back` and `:cancel` in input prompts.
- **Use saved Perch defaults** appears after you save a configuration. Advanced
  setup offers to save its non-secret settings in `/etc/perch-lxc/defaults`.
  The file is root-only, parsed as data rather than executed, and never stores a
  root password or CT ID. Each installation still gets a new ID and confirmation.

Advanced settings include:

| Area | Controls |
| --- | --- |
| Identity and storage | CT ID, hostname/FQDN, disk storage, template storage |
| Resources | CPU, RAM, swap, root disk size |
| Networking | Bridge/active SDN VNet, IPv4 DHCP/static, gateway, IPv6 none/SLAAC/DHCP/static |
| Network details | IPv4/IPv6 DNS, search domain, VLAN, MTU, MAC, interface firewall |
| Container settings | Tags, timezone, start at boot, deletion protection |
| Access | Optional root console password and public-key-only root SSH |
| Application | HTTP port and release version |

SSH is disabled and masked by default, including socket activation. If you select
a public-key file on the host, the installer supplies it to Proxmox, installs
OpenSSH in the CT and enables key-only root access. A console password does not
enable password SSH. The UI never displays or saves that password.

IPv6 defaults to no address assignment (`manual` in PVE). When enabled, the
installer sets `HOST=::` and verifies both IPv6 and IPv4 HTTP access; this requires
Linux dual-stack sockets (`net.ipv6.bindv6only=0`). The normal IPv4-only default
continues to use `HOST=0.0.0.0`. VLANs, MTUs and static routes must also be supported
by your physical network.

Ports must be 1–65535. Port 80 requires release `v0.1.2` or newer; older releases
can use a port such as 3000. Existing CT/VM IDs are always refused. Failed installs
retain the new CT and print inspection commands; no CT is automatically deleted.

The installer uses an unprivileged Debian 13 CT with nesting enabled for systemd
isolation. Privileged containers, device passthrough and post-install hooks are
not supported.

The 512 MiB RAM default gives Debian and APT more headroom during installation;
Advanced can select 256 MiB. These remain **starting defaults, not measured
Proxmox minimums**. Perch's single-thread service has no server-side image
processing, but Debian, APT, logs and app data also need resources. Maximum
supported inline logos can consume about 12 MB of JSON before in-memory overhead.
Increase resources for your workload; footprint and peak installation memory
still need real-host measurement.

After installation, use `pct exec 123 -- hostname -I` to find the address, then open
`http://<container-ip>/` (replace `123` throughout with your CT ID).

### Native service configuration

The binary is `/usr/local/bin/perch`, running as the dedicated `perch` system user.
Data lives at **`/var/lib/perch/apps.json`**, owned by `perch:perch`, with directory
mode `0750` and file mode `0640`. The directory stays writable for atomic saves.

`/etc/default/perch` contains:

```ini
HOST=0.0.0.0
PORT=80
PERCH_DATA=/var/lib/perch/apps.json
```

For a custom port, edit that file inside the CT and run `systemctl restart perch`.
Keep `HOST` reachable over loopback for update health checks and keep `PERCH_DATA`
at the managed path. The systemd service restarts on failure, grants only `CAP_NET_BIND_SERVICE` so
the `perch` user can bind port 80, blocks privilege escalation and makes the filesystem read-only except for the
state directory and private temporary storage. Local overrides belong in
`systemctl edit perch`.

**There is no built-in authentication or TLS.** Anyone with network access can
read and modify your shortcuts. Do not forward this port to the internet. Restrict
access with your network/firewall or use an authenticated HTTPS reverse proxy.
An unprivileged LXC and systemd hardening do not replace access control.
The installer enables `nesting=1` because Proxmox requires it for systemd service
isolation. This also exposes host procfs/sysfs contents to the guest, as described
in the [Proxmox container configuration documentation](https://raw.githubusercontent.com/proxmox/pve-docs/master/generated/pct.conf.5-opts.adoc).

### Existing installations on port 3000

Binary updates preserve your configuration and service unit, so they do not change
an existing installation's port. To switch an existing CT to standard HTTP, run
these commands as root **inside that CT** (`pct enter 123` from the host):

```bash
mkdir -p /etc/systemd/system/perch.service.d
cat > /etc/systemd/system/perch.service.d/http.conf <<'EOF'
[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
EOF
sed -i 's/^PORT=.*/PORT=80/' /etc/default/perch
systemctl daemon-reload
systemctl restart perch
```

Then open `http://<container-ip>/`. This does not touch your collection. Ensure
port 80 is available and permitted by your firewall. Manually launched builds retain their port 3000 default. Docker listens on
port 3000 inside the container; the [documented Docker command](installation.md#docker)
publishes it on host port 80.

### Updates and backups

From the Proxmox host:

```bash
pct exec 123 -- perch-update
```

Or run `perch-update` as root inside the CT. To choose a published version:

```bash
pct exec 123 -- perch-update v0.1.3
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
pct exec 123 -- curl -f http://127.0.0.1/api/apps
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
it, verify the CT ID, and then explicitly run (clear protection if you enabled it):

```bash
pct stop 123
pct set 123 --protection 0
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
