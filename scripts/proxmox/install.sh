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

perch_check_release_port() {
    if (($2 < 1024)) && ! grep -Fxq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$1/perch.service"; then
        perch_die 'This release cannot bind low ports. Choose v0.1.2 or newer, or select a port such as 3000.'
    fi
}

perch_create_ct() (
    local id=$1 volume=$2
    shift 2
    perch_assert_unused_id "$id"
    # PVE requires nesting for systemd's filesystem namespace isolation.
    # Template extraction must not inherit our restrictive host-file umask.
    umask 022
    pct create "$id" "$volume" --unprivileged 1 --features nesting=1 "$@"
)

# Configuration is kept as data; no saved file is ever sourced or evaluated.
PERCH_FIELDS=(CTID HOSTNAME STORAGE TEMPLATE_STORAGE CORES MEMORY SWAP DISK BRIDGE IP GATEWAY IPV6 GATEWAY6 DNS SEARCHDOMAIN VLAN MTU MAC FIREWALL TAGS TIMEZONE ONBOOT PROTECTION ROOT_PASSWORD SSH_KEYS PORT VERSION)
PERCH_SAVED_FIELDS=(HOSTNAME STORAGE TEMPLATE_STORAGE CORES MEMORY SWAP DISK BRIDGE IP GATEWAY IPV6 GATEWAY6 DNS SEARCHDOMAIN VLAN MTU MAC FIREWALL TAGS TIMEZONE ONBOOT PROTECTION SSH_KEYS PORT VERSION)

perch_bridges() {
    local entry
    {
        for entry in /sys/class/net/*/bridge; do
            [[ -d $entry ]] && basename "$(dirname "$entry")"
        done
        if command -v ovs-vsctl > /dev/null; then ovs-vsctl list-br 2>/dev/null || true; fi
    } | sort -u
}

perch_set_defaults() {
    CTID=$(pvesh get /cluster/nextid)
    HOSTNAME=perch CORES=1 MEMORY=512 SWAP=256 DISK=2 PORT=80 VERSION=latest
    IP=dhcp GATEWAY='' IPV6=manual GATEWAY6='' DNS=inherit SEARCHDOMAIN=inherit
    VLAN=none MTU=inherit MAC=auto FIREWALL=1 TAGS='perch;dashboard'
    TIMEZONE=host ONBOOT=1 PROTECTION=0 ROOT_PASSWORD='' SSH_KEYS=none
    STORAGE=$(head -1 <<< "$roots")
    if grep -Fxq local-lvm <<< "$roots"; then STORAGE=local-lvm; fi
    TEMPLATE_STORAGE=$(head -1 <<< "$templates")
    BRIDGE=$(perch_bridges | head -1)
    if perch_bridges | grep -Fxq vmbr0; then BRIDGE=vmbr0; fi
}

perch_in_range() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,8})$ ]] && (($1 >= $2 && $1 <= $3))
}

perch_hostname() {
    local label
    local -a labels
    [[ -n $1 && ${#1} -le 253 && $1 != *. && $1 != .* && $1 != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

perch_ipv6() {
    [[ $1 == *:* && $1 != *%* ]] || return 1
    perl -MSocket=inet_pton,AF_INET6 -e 'exit(defined inet_pton(AF_INET6, $ARGV[0]) ? 0 : 1)' "$1" 2>/dev/null
}

perch_cidr4() {
    [[ $1 == */* ]] && perch_ipv4 "${1%/*}" && perch_in_range "${1##*/}" 1 32
}

perch_cidr6() {
    [[ $1 == */* ]] && perch_ipv6 "${1%/*}" && perch_in_range "${1##*/}" 1 128
}

perch_gateway4() {
    local ip_value gateway_value mask octet
    local -a octets
    perch_ipv4 "$1" && perch_cidr4 "$IP" || return 1
    ip_value=0 gateway_value=0
    IFS=. read -r -a octets <<< "${IP%/*}"
    for octet in "${octets[@]}"; do ip_value=$((ip_value * 256 + octet)); done
    IFS=. read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do gateway_value=$((gateway_value * 256 + octet)); done
    mask=$(((0xFFFFFFFF << (32 - ${IP##*/})) & 0xFFFFFFFF))
    (( (ip_value & mask) == (gateway_value & mask) ))
}

perch_validate_field() {
    local field=$1 value=$2 item first
    [[ $value != *[[:cntrl:]]* ]] || return 1
    local -a servers
    case "$field" in
        CTID) perch_in_range "$value" 100 999999999 && pvesh get /cluster/nextid --vmid "$value" > /dev/null 2>&1 ;;
        HOSTNAME) perch_hostname "$value" ;;
        STORAGE) grep -Fxq -- "$value" <<< "$roots" ;;
        TEMPLATE_STORAGE) grep -Fxq -- "$value" <<< "$templates" ;;
        CORES) perch_in_range "$value" 1 "$(nproc)" ;;
        MEMORY) perch_in_range "$value" 256 1048576 ;;
        SWAP) perch_in_range "$value" 0 1048576 ;;
        DISK) perch_in_range "$value" 2 1048576 ;;
        PORT) perch_in_range "$value" 1 65535 ;;
        BRIDGE) [[ -n $value ]] && perch_bridges | grep -Fxq -- "$value" ;;
        IP) [[ $value == dhcp ]] || perch_cidr4 "$value" ;;
        GATEWAY) [[ $IP == dhcp && -z $value ]] || perch_gateway4 "$value" ;;
        IPV6) [[ $value == auto || $value == dhcp || $value == manual ]] || perch_cidr6 "$value" ;;
        GATEWAY6) [[ -z $value ]] || { perch_cidr6 "$IPV6" && perch_ipv6 "$value"; } ;;
        DNS)
            [[ $value == inherit ]] && return 0
            [[ -n $value ]] || return 1
            read -r -a servers <<< "$value"
            for item in "${servers[@]}"; do perch_ipv4 "$item" || perch_ipv6 "$item" || return 1; done
            ;;
        SEARCHDOMAIN) [[ $value == inherit || $value == none ]] || perch_hostname "$value" ;;
        VLAN) [[ $value == none ]] || perch_in_range "$value" 1 4094 ;;
        MTU) [[ $value == inherit ]] || perch_in_range "$value" 576 65535 ;;
        MAC)
            [[ $value == auto ]] && return 0
            [[ $value =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ && $value != 00:00:00:00:00:00 ]] || return 1
            first=${value%%:*}
            (( (16#$first & 1) == 0 ))
            ;;
        FIREWALL|ONBOOT|PROTECTION) [[ $value == 0 || $value == 1 ]] ;;
        TAGS) [[ $value == none || $value =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*(\;[a-zA-Z0-9_][a-zA-Z0-9_-]*)*$ ]] ;;
        TIMEZONE) [[ $value == host ]] || { [[ $value =~ ^[a-zA-Z0-9_+/-]+$ && $value != *..* && $value != /* ]] && [[ -f /usr/share/zoneinfo/$value ]]; } ;;
        ROOT_PASSWORD) [[ -z $value ]] || { [[ ${#value} -ge 8 && $value != *[[:cntrl:]]* ]]; } ;;
        SSH_KEYS)
            [[ $value == none ]] && return 0
            [[ -f $value ]] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$value" && ssh-keygen -lf "$value" > /dev/null 2>&1
            ;;
        VERSION) [[ $value == latest || $value =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ;;
        *) return 1 ;;
    esac
}

perch_notice() {
    if [[ ${PERCH_UI:-plain} == dialog ]]; then
        whiptail --title Perch --msgbox "$1" 12 76 <&3 >&2
    else
        printf '\n%s\n' "$1" >&2
    fi
}

perch_yes() {
    local yes_label=${2:-Confirm} no_label=${3:-Back}
    if [[ ${PERCH_UI:-plain} == dialog ]]; then
        whiptail --title Perch --defaultno --yes-button "$yes_label" --no-button "$no_label" --yesno "$1" 20 78 <&3 >&2
    else
        local response
        printf '\n%s\n%s? [y/N]: ' "$1" "$yes_label" >&2
        IFS= read -r response <&3 || return 1
        [[ $response == y || $response == Y ]]
    fi
}

perch_menu() {
    # FD 3 is the terminal input; FD 4 captures only the dialog answer.
    local variable=$1 title=$2 current=$3 selection cancel_label=Back
    shift 3
    [[ $title != 'Choose an installation mode' ]] || cancel_label=Exit
    if [[ ${PERCH_UI:-plain} == dialog ]]; then
        selection=$(whiptail --title Perch --backtitle "${PERCH_PROGRESS:-Perch · Proxmox VE installer}" \
            --ok-button Select --cancel-button "$cancel_label" --default-item "$current" --menu "$title" 20 78 10 "$@" 4>&1 1>&2 2>&4 <&3) || return 1
    else
        printf '\n%s\n' "$title" >&2
        while (($#)); do printf '  %s  %s\n' "$1" "$2" >&2; shift 2; done
        printf 'Selection [%s] (:back to return): ' "$current" >&2
        IFS= read -r selection <&3 || return 1
        [[ $selection != :back && $selection != :cancel ]] || return 1
        selection=${selection:-$current}
    fi
    printf -v "$variable" '%s' "$selection"
}

perch_input() {
    local variable=$1 label=$2 current=$3 secret=${4:-no} response
    if [[ ${PERCH_UI:-plain} == dialog ]]; then
        if [[ $secret == yes ]]; then
            response=$(whiptail --title Perch --backtitle "${PERCH_PROGRESS:-Advanced setup}" --ok-button Next --cancel-button Back --passwordbox "$label" 12 78 4>&1 1>&2 2>&4 <&3) || return 1
        else
            response=$(whiptail --title Perch --backtitle "${PERCH_PROGRESS:-Advanced setup}" --ok-button Next --cancel-button Back --inputbox "$label" 12 78 "$current" 4>&1 1>&2 2>&4 <&3) || return 1
        fi
    else
        printf '\n%s [%s] (:back / :cancel): ' "$label" "${current:-empty}" >&2
        if [[ $secret == yes ]]; then
            IFS= read -rs response <&3 || return 2
            printf '\n' >&2
        else
            IFS= read -r response <&3 || return 2
        fi
        [[ $response != :back ]] || return 1
        [[ $response != :cancel ]] || return 2
        response=${response:-$current}
    fi
    printf -v "$variable" '%s' "$response"
}

perch_ask_field() {
    local field=$1 label value confirmation status item
    local -a choices
    case "$field" in
        CTID) label='Container ID (100–999999999; must be unused cluster-wide)' ;;
        HOSTNAME) label='Hostname or FQDN (e.g. perch or perch.home.arpa)' ;;
        STORAGE) label='Container disk storage' ;;
        TEMPLATE_STORAGE) label='Debian template storage' ;;
        CORES) label="CPU cores (1–$(nproc))" ;;
        MEMORY) label='RAM in MiB (minimum 256; recommended 512 for Debian installation)' ;;
        SWAP) label='Swap in MiB (0 disables swap)' ;;
        DISK) label='Root disk in GiB (minimum 2)' ;;
        BRIDGE) label='Network bridge or active SDN VNet' ;;
        IP) label='IPv4: dhcp or static address/prefix (e.g. 192.168.1.50/24)' ;;
        GATEWAY) label='IPv4 gateway (must be in the same subnet)' ;;
        IPV6) label='IPv6: manual (no assignment), auto (SLAAC), dhcp, or address/prefix' ;;
        GATEWAY6) label='IPv6 gateway (empty for none)' ;;
        DNS) label='DNS servers: inherit or space-separated IPv4/IPv6 addresses' ;;
        SEARCHDOMAIN) label='DNS search domain: inherit, none, or a DNS suffix' ;;
        VLAN) label='VLAN tag: none or 1–4094 (bridge must support the VLAN)' ;;
        MTU) label='MTU: inherit or 576–65535 (must fit your network)' ;;
        MAC) label='MAC: auto or a unicast address (e.g. 02:00:00:00:00:01)' ;;
        FIREWALL) label='Apply Proxmox interface firewall rules? (1=yes, 0=no)' ;;
        TAGS) label='Container tags: semicolon-separated (e.g. perch;dashboard), or none' ;;
        TIMEZONE) label='Container timezone: host or a zone such as Europe/London' ;;
        ONBOOT) label='Start container when the host boots? (1=yes, 0=no)' ;;
        PROTECTION) label='Enable container deletion protection? (1=yes, 0=no)' ;;
        ROOT_PASSWORD) label='Optional root console password (8+ characters); empty leaves root password locked' ;;
        SSH_KEYS) label='Optional SSH public-key file on this host, or none (SSH disabled)' ;;
        PORT) label='HTTP port (1–65535; 80 needs no URL port suffix)' ;;
        VERSION) label='Perch release: latest or vX.Y.Z' ;;
        *) return 2 ;;
    esac
    while true; do
        value=''
        case "$field" in
            STORAGE|TEMPLATE_STORAGE|BRIDGE)
                choices=()
                case "$field" in
                    STORAGE) value=$roots ;;
                    TEMPLATE_STORAGE) value=$templates ;;
                    BRIDGE) value=$(perch_bridges) ;;
                esac
                while IFS= read -r item; do [[ -z $item ]] || choices+=("$item" 'available'); done <<< "$value"
                if perch_menu value "$label" "${!field}" "${choices[@]}"; then :; else return 1; fi
                ;;
            ROOT_PASSWORD)
                if perch_input value "$label" '' yes; then :; else status=$?; return "$status"; fi
                if [[ -n $value ]]; then
                    if perch_input confirmation 'Confirm root password' '' yes; then :; else status=$?; return "$status"; fi
                    if [[ $value != "$confirmation" ]]; then perch_notice 'Passwords do not match.'; continue; fi
                fi
                ;;
            *)
                if perch_input value "$label" "${!field}"; then :; else status=$?; return "$status"; fi
                ;;
        esac
        if perch_validate_field "$field" "$value"; then
            printf -v "$field" '%s' "$value"
            if [[ $field == IP && $value == dhcp ]]; then GATEWAY=''; fi
            if [[ $field == IPV6 && $value != */* ]]; then GATEWAY6=''; fi
            return 0
        fi
        perch_notice "Invalid setting: $label. Please correct it."
    done
}

perch_review() {
    local field root_status='locked' ssh_status='disabled'
    for field in "${PERCH_FIELDS[@]}"; do
        if ! perch_validate_field "$field" "${!field}"; then
            perch_notice "Invalid $field setting. Use Advanced Install to correct it."
            return 1
        fi
    done
    [[ -z $ROOT_PASSWORD ]] || root_status='configured (hidden)'
    [[ $SSH_KEYS == none ]] || ssh_status='public-key authentication only'
    perch_yes "Create unprivileged Debian 13 CT $CTID ($HOSTNAME)?
CPU $CORES · RAM $MEMORY MiB · swap $SWAP MiB · disk $DISK GiB
Disk storage: $STORAGE · template storage: $TEMPLATE_STORAGE
Network: $BRIDGE · IPv4 $IP ${GATEWAY:+via $GATEWAY} · IPv6 $IPV6
DNS: $DNS · search: $SEARCHDOMAIN
VLAN: $VLAN · MTU: $MTU · MAC: $MAC · firewall: $FIREWALL
Tags: $TAGS · timezone: $TIMEZONE · boot: $ONBOOT · protection: $PROTECTION
Root password: $root_status · SSH: $ssh_status
Perch: $VERSION · HTTP port $PORT
Nesting stays enabled for systemd isolation.
No Perch authentication: restrict access to a trusted LAN or authenticated proxy." Create Back
}

perch_advanced() {
    local step=0 direction=1 status field
    while ((step >= 0)); do
        if ((step == ${#PERCH_FIELDS[@]})); then
            if perch_review; then return 0; fi
            direction=-1; step=$((step-1)); continue
        fi
        field=${PERCH_FIELDS[step]}
        PERCH_PROGRESS="Advanced setup · step $((step+1))/${#PERCH_FIELDS[@]}"
        if [[ $field == GATEWAY && $IP == dhcp ]] || [[ $field == GATEWAY6 && $IPV6 != */* ]]; then
            step=$((step+direction)); continue
        fi
        if perch_ask_field "$field"; then
            direction=1
        else
            status=$?
            ((status != 2)) || return 2
            direction=-1
        fi
        step=$((step+direction))
    done
    return 1
}

perch_load_defaults() {
    local file=$1 key value allowed field
    [[ -f $file ]] || return 1
    while IFS='=' read -r key value || [[ -n $key ]]; do
        [[ -z $key || $key == \#* ]] && continue
        allowed=0
        for field in "${PERCH_SAVED_FIELDS[@]}"; do [[ $key != "$field" ]] || allowed=1; done
        if (( !allowed )); then perch_notice "Unsupported saved default: $key"; return 1; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    # Validate all values after parsing: dependent settings may appear in any order.
    for field in "${PERCH_SAVED_FIELDS[@]}"; do
        perch_validate_field "$field" "${!field}" || { perch_notice "Invalid saved default: $field"; return 1; }
    done
}

perch_save_defaults() {
    local file=$1 field temporary
    install -d -m 0700 "$(dirname "$file")" || return 1
    temporary=$(mktemp "${file}.XXXXXX") || return 1
    # Explicit checks matter: callers run within menu conditionals, disabling errexit.
    if ! (
        for field in "${PERCH_SAVED_FIELDS[@]}"; do
            printf '%s=%s\n' "$field" "${!field}" || exit 1
        done
    ) > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! chmod 0600 "$temporary" || ! mv -f -- "$temporary" "$file"; then
        rm -f -- "$temporary"
        return 1
    fi
}

perch_choose_settings() {
    local choice
    local -a items
    while true; do
        PERCH_PROGRESS=''
        items=(1 'Default Install' 2 'Advanced Install')
        [[ ! -f $DEFAULTS_FILE ]] || items+=(3 'Use saved Perch defaults')
        items+=(0 Exit)
        if ! perch_menu choice 'Choose an installation mode' 1 "${items[@]}"; then return 1; fi
        case "$choice" in
            1)
                perch_set_defaults
                if [[ $(wc -l <<< "$roots") -gt 1 ]]; then perch_ask_field STORAGE || continue; fi
                if [[ $(wc -l <<< "$templates") -gt 1 ]]; then perch_ask_field TEMPLATE_STORAGE || continue; fi
                if perch_review; then return 0; fi
                ;;
            2)
                if perch_advanced; then
                    if perch_yes 'Save these non-secret settings as Perch defaults for future installations?' Save 'Skip saving'; then
                        perch_save_defaults "$DEFAULTS_FILE" || perch_die 'Could not save defaults. Previous defaults retained; no CT created.'
                    fi
                    return 0
                fi
                ;;
            3)
                perch_set_defaults
                if perch_load_defaults "$DEFAULTS_FILE" && perch_review; then return 0; fi
                ;;
            0) return 1 ;;
            *) perch_notice 'Choose one of the listed installation modes.' ;;
        esac
    done
}

perch_provision() {
    local volume=$1 net
    net="name=eth0,bridge=$BRIDGE,ip=$IP,ip6=$IPV6,type=veth,firewall=$FIREWALL"
    [[ -z $GATEWAY ]] || net+=",gw=$GATEWAY"
    [[ -z $GATEWAY6 ]] || net+=",gw6=$GATEWAY6"
    [[ $VLAN == none ]] || net+=",tag=$VLAN"
    [[ $MTU == inherit ]] || net+=",mtu=$MTU"
    [[ $MAC == auto ]] || net+=",hwaddr=$MAC"
    local -a options=(--hostname "$HOSTNAME" --onboot "$ONBOOT" --cores "$CORES"
        --memory "$MEMORY" --swap "$SWAP" --rootfs "$STORAGE:$DISK" --net0 "$net"
        --ostype debian --timezone "$TIMEZONE" --protection "$PROTECTION"
        --description 'Perch homelab dashboard (no authentication)')
    [[ $DNS == inherit ]] || options+=(--nameserver "$DNS")
    case "$SEARCHDOMAIN" in
        inherit) ;;
        none) options+=(--searchdomain '') ;;
        *) options+=(--searchdomain "$SEARCHDOMAIN") ;;
    esac
    [[ $TAGS == none ]] || options+=(--tags "$TAGS")
    [[ $SSH_KEYS == none ]] || options+=(--ssh-public-keys "$SSH_KEYS")
    perch_create_ct "$CTID" "$volume" "${options[@]}"
}

perch_configure_bind() {
    [[ $IPV6 != manual ]] || return 0
    # Linux's dual-stack listener must also serve IPv4 for updater health checks.
    # shellcheck disable=SC2016 # $1 and procfs are evaluated inside the container.
    pct exec "$CTID" -- bash -c 'set -e
        if [[ $(cat /proc/sys/net/ipv6/bindv6only) != 0 ]]; then
            echo "IPv6 requires dual-stack sockets (net.ipv6.bindv6only=0). Check container network settings." >&2
            exit 1
        fi
        sed -i "s/^HOST=.*/HOST=::/" /etc/default/perch
        systemctl restart perch
        for ((attempt=0; attempt<20; attempt++)); do
            if curl -fgsS --noproxy "*" "http://[::1]:$1/api/apps" > /dev/null &&
               curl -fsS --noproxy "*" "http://127.0.0.1:$1/api/apps" > /dev/null; then exit 0; fi
            sleep 1
        done
        echo "Dual-stack Perch listener failed its HTTP health check." >&2
        exit 1' bash "$PORT"
}

perch_configure_ssh() {
    if [[ $SSH_KEYS == none ]]; then
        pct exec "$CTID" -- bash -c 'set -e
            systemctl stop ssh.service ssh.socket 2>/dev/null || true
            systemctl mask ssh.service ssh.socket'
    else
        pct exec "$CTID" -- bash -c 'set -e
            export DEBIAN_FRONTEND=noninteractive
            mkdir -p /etc/ssh/sshd_config.d /run/sshd
            printf "PermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n" > /etc/ssh/sshd_config.d/00-perch.conf
            systemctl unmask ssh.service ssh.socket
            apt-get install -y --no-install-recommends openssh-server
            sshd -t
            systemctl disable --now ssh.socket 2>/dev/null || true
            systemctl enable --now ssh
            systemctl restart ssh'
    fi
}

perch_url() {
    local address=$1 port=$2
    [[ $address != *:* ]] || address="[$address]"
    if [[ $port == 80 ]]; then printf 'http://%s' "$address"; else printf 'http://%s:%s' "$address" "$port"; fi
}

perch_host_main() (
    [[ $EUID == 0 ]] || perch_die 'Run this script as root on a Proxmox VE host.'
    local command
    for command in pveversion pct pveam pvesm pvesh curl sha256sum tar awk flock perl ssh-keygen; do
        command -v "$command" > /dev/null || perch_die "Required host command not found: $command"
    done
    pveversion | grep -q '^pve-manager/' || perch_die 'This is not a Proxmox VE host.'
    [[ $(uname -m) == x86_64 ]] || perch_die 'Only x86_64 hosts are currently supported.'
    exec 9>/run/lock/perch-lxc-install.lock
    flock -n 9 || perch_die 'Another Perch LXC installer is running.'
    exec 3</dev/tty || perch_die 'An interactive terminal is required.'
    CTID='' work='' attempted=0 complete=0
    DEFAULTS_FILE=/etc/perch-lxc/defaults
    PERCH_UI=plain
    local lines=0 columns=0
    read -r lines columns < <(stty size <&3) || true
    if command -v whiptail > /dev/null && [[ ${TERM:-dumb} != dumb && -t 2 ]] && ((lines >= 24 && columns >= 80)); then
        PERCH_UI=dialog
    fi
    # shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap (ShellCheck 0.9+).
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
    printf '\nPerch · Debian 13 unprivileged LXC\nNo Rust, Node.js or Docker will be installed.\n' >&2
    roots=$(pvesm status --content rootdir | awk 'NR > 1 && $3 == "active" {print $1}')
    templates=$(pvesm status --content vztmpl | awk 'NR > 1 && $3 == "active" {print $1}')
    [[ -n $roots && -n $templates ]] || perch_die 'Need active storage for rootdir and vztmpl content.'
    [[ -n $(perch_bridges) ]] || perch_die 'No Linux or Open vSwitch network bridge found.'
    perch_set_defaults
    if ! perch_choose_settings; then printf 'Installation cancelled.\n'; return 0; fi

    # Fail before creating a CT if releases/assets are not yet available.
    work=$(mktemp -d)
    perch_download "$work" "$VERSION"
    perch_check_release_port "$work/bundle" "$PORT"
    pveam update
    template=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -1)
    [[ -n $template ]] || perch_die 'No Debian 13 amd64 standard template available. Check your Proxmox version/template catalogue.'
    volume="$TEMPLATE_STORAGE:vztmpl/$template"
    if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR > 1 {print $1}' | grep -Fxq -- "$volume"; then
        pveam download "$TEMPLATE_STORAGE" "$template"
    fi
    attempted=1
    perch_provision "$volume"
    pct start "$CTID"
    # Wait for container boot and DNS; APT and release downloads also need network access.
    local ready=0 attempt
    for ((attempt=0; attempt<30; attempt++)); do
        if pct exec "$CTID" -- getent ahosts deb.debian.org > /dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    ((ready)) || perch_die 'Container networking did not become ready. Check bridge, gateway and DNS.'
    pct exec "$CTID" -- mkdir -p /root/perch-install
    pct push "$CTID" "$work/perch-x86_64-unknown-linux-musl.tar.gz" /root/perch-install/release.tar.gz
    pct push "$CTID" "$work/expected.sha256" /root/perch-install/expected.sha256
    # Verify the transferred archive again before executing its bootstrap.
    # shellcheck disable=SC2016 # $1 expands inside the container.
    pct exec "$CTID" -- bash -c 'set -e; cd /root/perch-install; mv release.tar.gz perch-x86_64-unknown-linux-musl.tar.gz; sha256sum --check expected.sha256; mkdir bundle; tar -xzf perch-x86_64-unknown-linux-musl.tar.gz -C bundle --no-same-owner; bash bundle/install-native.sh "$1"' bash "$PORT"
    if [[ -n $ROOT_PASSWORD ]]; then
        printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CTID" -- chpasswd
        ROOT_PASSWORD=''
    fi
    perch_configure_bind
    perch_configure_ssh
    pct exec "$CTID" -- rm -rf /root/perch-install
    complete=1
    local address url
    address=$(pct exec "$CTID" -- hostname -I | awk '{for(i=1;i<=NF;i++) if($i !~ /:/) {print $i;exit};print $1}')
    url=$(perch_url "${address:-<container-ip>}" "$PORT")
    printf '\nPerch installed in CT %s. Open %s/\n' "$CTID" "$url"
    printf 'Show addresses: pct exec %s -- hostname -I\nUpdate: pct exec %s -- perch-update\n' "$CTID" "$CTID"
)
# bash -c/stdin has no source filename; sourcing a file must remain side-effect free.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]:-} == "$0" ]]; then
    perch_host_main "$@"
fi
