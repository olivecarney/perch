#!/usr/bin/env bash
# Shared by the release bundle's native installer and updater.

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

perch_healthy() {
    local attempt port=3000
    # This file is root-owned and uses systemd EnvironmentFile syntax (no shell code).
    if [[ -f /etc/default/perch ]]; then
        port=$(sed -n 's/^PORT=//p' /etc/default/perch)
    fi
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
    for ((attempt=0; attempt<20; attempt++)); do
        if systemctl is-active --quiet perch &&
            curl --fail --silent --max-time 2 --noproxy '*' "http://127.0.0.1:$port/api/apps" > /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}
