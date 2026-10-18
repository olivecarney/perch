#!/usr/bin/env bash
# Original Perch installer; no code or framework from Community Scripts.
set -Eeuo pipefail
umask 077
perch_die() { printf 'Perch: %s\n' "$*" >&2; exit 1; }

# BEGIN RELEASE DOWNLOAD (also embedded in the standalone host installer)
perch_download() {
    local destination=$1 version=${2:-latest} base archive digest entry
    base=https://github.com/olivecarney/perch/releases
    archive=perch-x86_64-unknown-linux-musl.tar.gz
    mkdir -p "$destination/bundle"
    if [[ $version == latest ]]; then
        version=$(curl --fail --silent --show-error --location --proto '=https' \
            --connect-timeout 15 --max-time 60 --head --output /dev/null \
            --write-out '%{url_effective}' "$base/latest") ||
            perch_die 'Cannot resolve a published release. Check network access and publish a version tag first.'
        version=${version##*/}
    fi
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
        perch_die 'No compatible published release found. Publish a version tag first.'
    for entry in "$archive" SHA256SUMS; do
        curl --fail --silent --show-error --location --proto '=https' \
            --retry 3 --connect-timeout 15 --max-time 300 \
            --output "$destination/$entry" "$base/download/$version/$entry" ||
            perch_die "Cannot download $entry for $version; check that its release has finished publishing."
    done
    digest=$(awk -v name="$archive" '$2 == name {print $1}' "$destination/SHA256SUMS")
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || perch_die 'Missing or malformed release checksum.'
    printf '%s  %s\n' "$digest" "$archive" > "$destination/expected.sha256"
    (cd "$destination" && sha256sum --check expected.sha256) || perch_die 'Release checksum verification failed.'
    # Only regular files/directories with the exact bundle paths are allowed.
    tar -tzf "$destination/$archive" > "$destination/entries"
    while IFS= read -r entry; do
        case "$entry" in
            ./|./perch|./perch.service|./install-native.sh|./perch-update|./release-common.sh|./VERSION|./LICENSE|./THIRD_PARTY.md|./FONT-LICENSE.txt|./ICONS-LICENSE) ;;
            *) perch_die "Unexpected release archive member: $entry" ;;
        esac
    done < "$destination/entries"
    tar -tvzf "$destination/$archive" > "$destination/types"
    if awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {bad=1} END {exit !bad}' "$destination/types"; then
        perch_die 'Release archive contains links or special files.'
    fi
    tar -xzf "$destination/$archive" -C "$destination/bundle" --no-same-owner --no-same-permissions
    for entry in perch perch.service install-native.sh perch-update release-common.sh VERSION; do
        [[ -f $destination/bundle/$entry ]] || perch_die "Incomplete release: missing $entry"
    done
    [[ $(cat "$destination/bundle/VERSION") == "$version" ]] || perch_die 'Release version does not match archive.'
}
# END RELEASE DOWNLOAD

perch_ipv4() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((octet <= 255)) || return 1
    done
}

perch_number() {
    if ! [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || ! (($2 >= $3 && $2 <= $4)); then
        perch_die "$1 must be an integer between $3 and $4."
    fi
}

perch_assert_unused_id() {
    # Proxmox checks the entire cluster namespace, including QEMU guests.
    pvesh get /cluster/nextid --vmid "$1" > /dev/null 2>&1 ||
        perch_die "CT/VM ID $1 already exists or cannot be reserved. Choose another ID."
}

perch_create_ct() {
    local id=$1 volume=$2
    shift 2
    perch_assert_unused_id "$id"
    # PVE requires nesting for systemd's filesystem namespace isolation.
    pct create "$id" "$volume" --unprivileged 1 --features nesting=1 "$@"
}

perch_prompt() {
    local variable=$1 label=$2 default=$3 answer
    printf '%s [%s]: ' "$label" "$default" >&3
    IFS= read -r answer <&3 || perch_die 'Input closed; installation cancelled.'
    printf -v "$variable" '%s' "${answer:-$default}"
}

perch_host_main() (
    [[ $EUID == 0 ]] || perch_die 'Run this script as root on a Proxmox VE host.'
    local command
    for command in pveversion pct pveam pvesm pvesh curl sha256sum tar awk flock; do
        command -v "$command" > /dev/null || perch_die "Required host command not found: $command"
    done
    pveversion | grep -q '^pve-manager/' || perch_die 'This is not a Proxmox VE host.'
    [[ $(uname -m) == x86_64 ]] || perch_die 'Only x86_64 hosts are currently supported.'
    exec 9>/run/lock/perch-lxc-install.lock
    flock -n 9 || perch_die 'Another Perch LXC installer is running.'
    exec 3<>/dev/tty || perch_die 'An interactive terminal is required.'
    CTID='' HOSTNAME='' IP='' GATEWAY='' DNS='' STORAGE='' TEMPLATE_STORAGE='' CORES='' MEMORY='' SWAP='' DISK='' PORT='' BRIDGE='' VERSION=''
    roots='' templates='' default_storage='' template='' volume='' net='' work='' attempted=0 complete=0 address='' answer='' prefix='' ns=''
    # shellcheck disable=SC2329 # Invoked by the EXIT trap.
    cleanup_host() {
        local status=$?
        trap - EXIT INT TERM
        [[ -z $work ]] || rm -rf -- "$work"
        if ((attempted && !complete)); then
            printf '\nInstallation did not finish. Any new CT %s is retained for inspection.\n' "$CTID" >&2
            printf 'Inspect: pct status %s; pct config %s\n' "$CTID" "$CTID" >&2
            printf 'Logs: pct exec %s -- journalctl -u perch --no-pager\n' "$CTID" >&2
            printf 'No container has been automatically deleted.\n' >&2
        fi
        exit "$status"
    }
    trap cleanup_host EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '\nPerch · Debian 13 unprivileged LXC\nNo Rust, Node.js or Docker will be installed.\n' >&3
    roots=$(pvesm status --content rootdir | awk 'NR > 1 && $3 == "active" {print $1}')
    templates=$(pvesm status --content vztmpl | awk 'NR > 1 && $3 == "active" {print $1}')
    [[ -n $roots && -n $templates ]] || perch_die 'Need active storage for rootdir and vztmpl content.'
    default_storage=$(head -1 <<< "$roots")
    if grep -Fxq local-lvm <<< "$roots"; then default_storage=local-lvm; fi
    perch_prompt CTID 'Container ID' "$(pvesh get /cluster/nextid)"
    perch_number 'CT ID' "$CTID" 100 999999999
    perch_assert_unused_id "$CTID"
    perch_prompt HOSTNAME 'Hostname' perch
    [[ ${#HOSTNAME} -le 63 && $HOSTNAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
        perch_die 'Hostname must be a single DNS label (letters, digits and internal hyphens; max 63).'
    perch_prompt BRIDGE 'Network bridge' vmbr0
    [[ $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ && -d /sys/class/net/$BRIDGE ]] || perch_die 'Network bridge does not exist.'
    perch_prompt IP 'IPv4 (dhcp or address/prefix)' dhcp
    GATEWAY=''
    if [[ $IP != dhcp ]]; then
        [[ $IP == */* ]] || perch_die 'Static IPv4 requires CIDR notation, e.g. 192.168.1.50/24.'
        address=${IP%/*}; prefix=${IP##*/}
        perch_ipv4 "$address" || perch_die 'Invalid static IPv4 address.'
        perch_number 'IPv4 prefix' "$prefix" 1 32
        perch_prompt GATEWAY 'IPv4 gateway' ''
        perch_ipv4 "$GATEWAY" || perch_die 'A valid IPv4 gateway is required for static networking.'
    fi
    perch_prompt DNS 'DNS IPv4 servers (space-separated; inherit for host settings)' inherit
    if [[ $DNS != inherit ]]; then
        [[ -n $DNS ]] || perch_die 'DNS cannot be empty.'
        for ns in $DNS; do perch_ipv4 "$ns" || perch_die "Invalid DNS IPv4 address: $ns"; done
    fi
    printf 'Active container storage:\n%s\n' "$roots" >&3
    perch_prompt STORAGE 'Container storage' "$default_storage"
    grep -Fxq -- "$STORAGE" <<< "$roots" || perch_die 'Selected storage does not support active rootdir content.'
    printf 'Active template storage:\n%s\n' "$templates" >&3
    perch_prompt TEMPLATE_STORAGE 'Template storage' "$(head -1 <<< "$templates")"
    grep -Fxq -- "$TEMPLATE_STORAGE" <<< "$templates" || perch_die 'Selected storage does not support active vztmpl content.'
    perch_prompt CORES 'CPU cores' 1
    perch_prompt MEMORY 'RAM (MiB)' 256
    perch_prompt SWAP 'Swap (MiB; 0 to disable)' 256
    perch_prompt DISK 'Disk size (GiB)' 2
    perch_prompt PORT 'Application port' 3000
    perch_prompt VERSION 'Release (latest or vX.Y.Z)' latest
    perch_number 'CPU cores' "$CORES" 1 "$(nproc)"
    perch_number 'RAM (MiB)' "$MEMORY" 256 1048576
    if [[ $SWAP != 0 ]]; then perch_number 'Swap (MiB)' "$SWAP" 1 1048576; fi
    perch_number 'Disk size (GiB)' "$DISK" 2 1048576
    perch_number 'Application port' "$PORT" 1024 65535
    printf '\nCreate CT %s (%s), %s, bridge %s, storage %s\nCPU %s; RAM %s MiB; swap %s MiB; disk %s GiB; port %s; release %s\n' \
        "$CTID" "$HOSTNAME" "$IP" "$BRIDGE" "$STORAGE" "$CORES" "$MEMORY" "$SWAP" "$DISK" "$PORT" "$VERSION" >&3
    printf 'Perch has no authentication. Restrict access to a trusted LAN or authenticated proxy.\n' >&3
    printf 'Create this new container? [y/N]: ' >&3
    IFS= read -r answer <&3
    [[ $answer == y || $answer == Y ]] || perch_die 'Installation cancelled.'

    # Fail before creating a CT if releases/assets are not yet available.
    work=$(mktemp -d)
    perch_download "$work" "$VERSION"
    pveam update
    template=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -1)
    [[ -n $template ]] || perch_die 'No Debian 13 amd64 standard template available. Check your Proxmox version/template catalogue.'
    volume="$TEMPLATE_STORAGE:vztmpl/$template"
    if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR > 1 {print $1}' | grep -Fxq -- "$volume"; then
        pveam download "$TEMPLATE_STORAGE" "$template"
    fi
    net="name=eth0,bridge=$BRIDGE,ip=$IP,ip6=manual,type=veth,firewall=1"
    [[ -z $GATEWAY ]] || net+=",gw=$GATEWAY"
    local -a options=(--hostname "$HOSTNAME" --onboot 1 --cores "$CORES"
        --memory "$MEMORY" --swap "$SWAP" --rootfs "$STORAGE:$DISK" --net0 "$net"
        --ostype debian --description 'Perch homelab dashboard (no authentication)')
    if [[ $DNS != inherit ]]; then options+=(--nameserver "$DNS"); fi
    # Recheck after downloads; pct create also refuses existing IDs atomically.
    attempted=1
    perch_create_ct "$CTID" "$volume" "${options[@]}"
    pct start "$CTID"
    # Wait for container boot and outbound DNS/HTTPS; APT also needs network access.
    local ready=0 attempt
    for ((attempt=0; attempt<30; attempt++)); do
        if pct exec "$CTID" -- getent ahostsv4 deb.debian.org > /dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    ((ready)) || perch_die 'Container networking did not become ready. Check bridge, gateway and DNS.'
    pct exec "$CTID" -- mkdir -p /root/perch-install
    pct push "$CTID" "$work/perch-x86_64-unknown-linux-musl.tar.gz" /root/perch-install/release.tar.gz
    pct push "$CTID" "$work/expected.sha256" /root/perch-install/expected.sha256
    # Verify the transferred archive again before executing its bootstrap.
    # shellcheck disable=SC2016 # $1 expands inside the container.
    pct exec "$CTID" -- bash -c 'set -e; cd /root/perch-install; mv release.tar.gz perch-x86_64-unknown-linux-musl.tar.gz; sha256sum --check expected.sha256; mkdir bundle; tar -xzf perch-x86_64-unknown-linux-musl.tar.gz -C bundle --no-same-owner; bash bundle/install-native.sh "$1"' bash "$PORT"
    pct exec "$CTID" -- rm -rf /root/perch-install
    complete=1
    printf '\nPerch installed in CT %s. Open http://<container-ip>:%s\n' "$CTID" "$PORT"
    printf 'Show addresses: pct exec %s -- hostname -I\nUpdate: pct exec %s -- perch-update\n' "$CTID" "$CTID"
)
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then perch_host_main "$@"; fi
