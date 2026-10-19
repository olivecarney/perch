# Perch setup and Community Scripts comparison

Reviewed 19 October 2026 against Community Scripts' current entrypoints and shared
core. Perch's installer is independently implemented, with no sourced framework
and no copied substantial code. The upstream projects are MIT licensed.

## References inspected

- [ProxmoxVE README](https://github.com/community-scripts/ProxmoxVE)
- [Glance entrypoint](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/glance.sh)
- [Homepage entrypoint](https://github.com/community-scripts/ProxmoxVE/blob/main/ct/homepage.sh)
- [Current core loader](https://github.com/community-scripts/core/blob/main/core/build.func)
- [Mode menu](https://github.com/community-scripts/core/blob/main/ui/menu.func)
- [Advanced wizard](https://github.com/community-scripts/core/blob/main/ui/advanced.func)
- [Defaults](https://github.com/community-scripts/core/blob/main/ui/defaults.func)
- [PVE backend](https://github.com/community-scripts/core/blob/main/pve/backend.func)

Current upstream CT entrypoints load the shared core from a separate repository.
The older `ProxmoxVE/misc/build.func` is not the only relevant implementation.
The current core includes Default Install, Advanced Install, User Defaults,
optional app defaults and a Settings menu. Advanced is a 31-step wizard including
container type, password, identity/resources, bridge and IP settings, IPv6,
DNS/MAC/MTU/VLAN, tags, SSH, device features, proxies, timezone, protection and hooks.

## Perch's approach

Keep the familiar Default/Advanced workflow and useful dashboard customisation,
while retaining the original requirements: an unprivileged Debian LXC, a tiny
precompiled binary, no build tools in the CT, and no large framework dependency.

The installer supports a final review, per-field validation, Back navigation,
clean cancellation, storage menus and root-only reusable defaults. These defaults
are key/value data, not shell scripts, and exclude credentials and CT IDs.
Validation repeats after loading them; the previous file survives write failures.

Resources: 1 CPU, 512 MiB RAM, 256 MiB swap, 2 GiB disk. Glance's comparable Debian
installer uses 512 MiB RAM and 2 GiB disk, while its Alpine variant uses 256 MiB.
This informs installation headroom, not a measured Perch minimum. Advanced permits
256 MiB RAM. HTTP stays on port 80; SSH, IPv6 assignment and CT protection are off
by default. Host DNS/timezone and bridge MTU are inherited. Tags are `perch;dashboard`.

Perch additionally checks release availability and SHA-256 before CT creation,
refuses all existing CT/VM IDs, retains failed CTs and never destroys them.
Template extraction runs with umask 022, independently of host secret-file
permissions, to keep Debian directories usable by `_apt` and unprivileged services.

Optional IPv6 setup configures and health-checks the actual dual-stack listener;
optional SSH uses public keys only. Selecting no SSH stops and masks both daemon
and socket activation, even if the template contains them.

Deliberate differences: no privileged CTs, optional disabling of required nesting,
device passthrough, IP-range discovery, proxy/CA injection, arbitrary hooks,
telemetry, Community Scripts global defaults or framework settings. This is a
Perch installer with a similar setup experience, not an upstream Community Script
or an exact copy of every option.

## Validation boundary

Unit/transaction tests cover settings validation, wizard navigation, cancellation,
argv construction, defaults parsing/atomic writes, umask, releases and rollback.
Linux CI exercises real whiptail in a pseudo-terminal and the actual systemd
service, including IPv4/IPv6 HTTP and persistence across restart. PVE command
execution, networking on actual bridges/SDN, SSH provisioning and resource use
still require a real Proxmox host. A mocked `pct` test does not prove those paths.
