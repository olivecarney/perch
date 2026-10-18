#!/usr/bin/env bash
# Invoked from the verified release bundle inside a fresh Debian LXC.
set -Eeuo pipefail
umask 027
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/release-common.sh
source "$SCRIPT_DIR/release-common.sh"

main() {
    local port=${1:-80}
    [[ $EUID == 0 ]] || perch_die 'Native installation requires root.'
    [[ $(uname -m) == x86_64 ]] || perch_die 'Only x86_64 is currently supported.'
    if ! perch_valid_port "$port"; then
        perch_die 'Port must be an integer between 1 and 65535.'
    fi
    exec 9>/run/lock/perch-install.lock
    flock -n 9 || perch_die 'Another Perch install/update is running.'
    [[ ! -e /usr/local/bin/perch && ! -e /etc/systemd/system/perch.service ]] ||
        perch_die 'Perch is already installed. Use perch-update.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl
    if ! getent passwd perch > /dev/null; then
        useradd --system --user-group --home-dir /var/lib/perch --no-create-home --shell /usr/sbin/nologin perch
    fi
    # The directory must be writable: saves use a temporary file and rename.
    install -d -o perch -g perch -m 0750 /var/lib/perch
    if [[ ! -e /var/lib/perch/apps.json ]]; then
        (set -o noclobber; printf '[]\n' > /var/lib/perch/apps.json)
    fi
    chown perch:perch /var/lib/perch/apps.json
    chmod 0640 /var/lib/perch/apps.json
    install -d -m 0755 /usr/local/lib/perch
    install -m 0755 "$SCRIPT_DIR/perch" /usr/local/bin/perch
    install -m 0755 "$SCRIPT_DIR/perch-update" /usr/local/sbin/perch-update
    install -m 0644 "$SCRIPT_DIR/release-common.sh" "$SCRIPT_DIR/VERSION" /usr/local/lib/perch/
    install -m 0644 "$SCRIPT_DIR/perch.service" /etc/systemd/system/perch.service
    # Preserve any configuration on a partial-install retry.
    if [[ ! -e /etc/default/perch ]]; then
        printf 'HOST=0.0.0.0\nPORT=%s\nPERCH_DATA=/var/lib/perch/apps.json\n' "$port" > /etc/default/perch
        chmod 0644 /etc/default/perch
    fi
    systemctl daemon-reload
    systemctl enable --now perch
    perch_healthy || perch_die 'Service is unhealthy. Inspect journalctl -u perch --no-pager.'
    printf 'Perch installed and running on port %s.\n' "$port"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
