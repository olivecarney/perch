"""Shell transaction tests; no Proxmox host or systemd daemon is contacted."""
import hashlib
import io
import shlex
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Deployment(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def shell(self, script, body):
        return subprocess.run(['bash', '-c', 'set -Eeuo pipefail\nsource "$1"\n' + body,
                               'test', str(ROOT / script)], cwd=self.path,
                              text=True, capture_output=True)

    def test_host_entrypoint_supports_command_file_and_sourcing(self):
        # Replace only the host side effects; exercise the real entrypoint guard.
        script = (ROOT / 'scripts/proxmox/install.sh').read_text()
        boundary = script.rindex('\nif [[')
        script = (script[:boundary] + '\nperch_host_main() { printf "launched\\n"; }\n'
                  + script[boundary:])
        file = self.path / 'installer.sh'
        file.write_text(script)
        for command in [['bash', '-c', script], ['bash', str(file)],
                        ['bash', '-c', 'source "$1"', 'test', str(file)]]:
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = '' if 'source "$1"' in command else 'launched\n'
            self.assertEqual(result.stdout, expected)

    def test_old_release_with_low_port_is_rejected_before_install(self):
        bundle = self.path / 'bundle'
        bundle.mkdir()
        unit = bundle / 'perch.service'
        unit.write_text('AmbientCapabilities=\n')
        result = self.shell('scripts/proxmox/install.sh', 'perch_check_release_port "$PWD/bundle" 80')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('v0.1.2', result.stderr)
        result = self.shell('scripts/proxmox/install.sh', 'perch_check_release_port "$PWD/bundle" 3000')
        self.assertEqual(result.returncode, 0, result.stderr)
        unit.write_text('AmbientCapabilities=CAP_NET_BIND_SERVICE\n')
        result = self.shell('scripts/proxmox/install.sh', 'perch_check_release_port "$PWD/bundle" 80')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_http_port_validation(self):
        for value in ['80', '443', '3000', '65535']:
            result = self.shell('scripts/release-common.sh', f'perch_valid_port "{value}"')
            self.assertEqual(result.returncode, 0, result.stderr)
        for value in ['0', '080', '65536', '-1', '9999999999999999999999', '80;id']:
            result = self.shell('scripts/release-common.sh', f'perch_valid_port "{value}"')
            self.assertNotEqual(result.returncode, 0, value)

    def test_service_supports_port_80_without_running_as_root(self):
        import configparser
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.read(ROOT / 'deploy/perch.service')
        service = config['Service']
        self.assertEqual(service['User'], 'perch')
        self.assertIn('PORT=80', service['Environment'].split())
        self.assertEqual(service['CapabilityBoundingSet'], 'CAP_NET_BIND_SERVICE')
        self.assertEqual(service['AmbientCapabilities'], 'CAP_NET_BIND_SERVICE')
        self.assertEqual(service['NoNewPrivileges'], 'true')

    def test_default_mode_uses_safe_perch_resources(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            roots=$'local-lvm\\nfast'
            templates=local
            pvesh() { printf 123; }
            nproc() { printf 8; }
            perch_bridges() { printf 'vmbr0\\n'; }
            perch_set_defaults
            printf '%s\\n' "$CTID|$MEMORY|$SWAP|$CORES|$DISK|$PORT|$IP|$IPV6|$ONBOOT|$PROTECTION|$STORAGE"
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '123|512|256|1|2|80|dhcp|manual|1|0|local-lvm')

    def test_advanced_back_navigation_preserves_wizard(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            IP=dhcp IPV6=manual backed=0
            perch_ask_field() {
                printf '%s\\n' "$1" >> "$PWD/steps"
                if [[ $1 == CORES && $backed == 0 ]]; then backed=1; return 1; fi
            }
            perch_review() { return 0; }
            perch_advanced
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = (self.path / 'steps').read_text().splitlines()
        index = steps.index('CORES')
        self.assertEqual(steps[index + 1], 'TEMPLATE_STORAGE')
        self.assertNotIn('GATEWAY', steps)
        self.assertNotIn('GATEWAY6', steps)

    def test_network_options_reach_pct_without_shell_interpolation(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            CTID=123 HOSTNAME=perch CORES=1 MEMORY=512 SWAP=256 DISK=2 STORAGE=local-lvm
            BRIDGE=vmbr0 IP=192.168.10.5/24 GATEWAY=192.168.10.1 IPV6=auto GATEWAY6=''
            VLAN=10 MTU=1500 MAC=02:00:00:00:00:01 FIREWALL=1 DNS=1.1.1.1 SEARCHDOMAIN=lan
            TAGS='perch;dashboard' ONBOOT=1 PROTECTION=1 TIMEZONE=host SSH_KEYS=none
            perch_create_ct() { printf '%s\\n' "$@" > "$PWD/options"; }
            perch_provision local:vztmpl/debian.tar.zst
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.path / 'options').read_text().splitlines()
        net = args[args.index('--net0') + 1]
        for part in ['ip=192.168.10.5/24', 'gw=192.168.10.1', 'ip6=auto', 'tag=10',
                     'mtu=1500', 'hwaddr=02:00:00:00:00:01', 'firewall=1']:
            self.assertIn(part, net.split(','))
        self.assertEqual(args[args.index('--tags') + 1], 'perch;dashboard')
        self.assertEqual(args[args.index('--protection') + 1], '1')

    def test_template_extraction_uses_safe_umask_without_changing_caller(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            umask 077
            pvesh() { :; }
            pct() { umask > "$PWD/template-umask"; }
            perch_create_ct 123 local:vztmpl/debian.tar.zst
            umask
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'template-umask').read_text().strip(), '0022')
        self.assertEqual(result.stdout.strip(), '0077')

    def test_saved_defaults_are_data_and_never_executed(self):
        (self.path / 'defaults').write_text('HOSTNAME=$(touch pwned)\nROOT_PASSWORD=secret\n')
        result = self.shell('scripts/proxmox/install.sh', '''
            ROOT_PASSWORD=''
            perch_load_defaults "$PWD/defaults"
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / 'pwned').exists())

    def test_failed_defaults_write_keeps_previous_file(self):
        (self.path / 'defaults').write_text('HOSTNAME=previous\n')
        result = self.shell('scripts/proxmox/install.sh', '''
            PERCH_SAVED_FIELDS=(HOSTNAME)
            HOSTNAME=next
            printf() { builtin printf 'HOSTNAME=truncated\\n'; return 1; }
            if perch_save_defaults "$PWD/defaults"; then exit 0; else exit 1; fi
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.path / 'defaults').read_text(), 'HOSTNAME=previous\n')

    def test_disabled_ssh_stops_and_masks_both_activation_paths(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            CTID=123 SSH_KEYS=none
            systemctl() { printf '%s\\n' "$*" >> "$PWD/ssh-commands"; }
            export -f systemctl
            pct() { shift 3; "$@"; }
            perch_configure_ssh
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (self.path / 'ssh-commands').read_text()
        self.assertIn('stop ssh.service ssh.socket', commands)
        self.assertIn('mask ssh.service ssh.socket', commands)

    def test_url_formats_ipv6_and_omits_default_http_port(self):
        for address, port, expected in [('192.168.1.5', '80', 'http://192.168.1.5'),
                                        ('2001:db8::1', '80', 'http://[2001:db8::1]'),
                                        ('2001:db8::1', '3000', 'http://[2001:db8::1]:3000')]:
            result = self.shell('scripts/proxmox/install.sh', f'perch_url "{address}" "{port}"')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_advanced_settings_validation(self):
        valid = [('HOSTNAME', 'perch.home.arpa'), ('IPV6', '2001:db8::2/64'),
                 ('IPV6', 'auto'), ('GATEWAY', '192.168.1.1'),
                 ('DNS', '1.1.1.1 2606:4700:4700::1111'), ('MAC', '02:00:00:00:00:01'),
                 ('SEARCHDOMAIN', 'none.example'), ('TAGS', 'perch;dashboard'),
                 ('TIMEZONE', 'host'), ('VLAN', '4094'), ('SWAP', '0')]
        invalid = [('HOSTNAME', 'bad..name'), ('IPV6', '2001:::2/64'),
                   ('IPV6', '2001:db8::2/129'), ('GATEWAY', '10.0.0.1'),
                   ('DNS', '1.1.1.1,tag=2'), ('MAC', '01:00:00:00:00:01'),
                   ('TAGS', 'perch;$(id)'), ('TIMEZONE', '../../etc/passwd'),
                   ('VLAN', '4095'), ('MTU', '1500,tag=2'), ('MEMORY', '128')]
        for expected, cases in [(0, valid), (1, invalid)]:
            for field, value in cases:
                result = self.shell('scripts/proxmox/install.sh',
                    'IP=192.168.1.5/24; IPV6=auto; perch_validate_field '
                    + shlex.quote(field) + ' ' + shlex.quote(value))
                self.assertEqual(result.returncode == 0, expected == 0, (field, value, result.stderr))

    def test_plain_default_and_cancel_modes(self):
        for answers, expected in [('1\ny\n', 'confirmed'), ('0\n', 'cancelled')]:
            (self.path / 'answers').write_text(answers)
            result = self.shell('scripts/proxmox/install.sh', '''
                pvesh() { printf 123; }
            nproc() { printf 8; }
                perch_bridges() { printf 'vmbr0\\n'; }
                roots=local-lvm templates=local PERCH_UI=plain DEFAULTS_FILE="$PWD/no-defaults"
                exec 3< "$PWD/answers"
                perch_set_defaults
                if perch_choose_settings; then printf confirmed; else printf cancelled; fi
            ''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_saved_defaults_round_trip_excludes_password_and_id(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            pvesh() { printf 123; }
            nproc() { printf 8; }
            perch_bridges() { printf 'vmbr0\\n'; }
            roots=local-lvm templates=local
            perch_set_defaults
            ROOT_PASSWORD='a-test-secret' HOSTNAME=custom
            perch_save_defaults "$PWD/saved/defaults"
            perch_set_defaults
            perch_load_defaults "$PWD/saved/defaults"
            printf '%s\\n' "$HOSTNAME|$CTID|$ROOT_PASSWORD"
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'custom|123|')
        file = self.path / 'saved/defaults'
        self.assertNotIn('ROOT_PASSWORD', file.read_text())
        self.assertNotIn('CTID=', file.read_text())
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def archive(self, bad_member=None, version='v0.1.0', symlink=False):
        archive = self.path / 'release.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ['perch', 'perch.service', 'install-native.sh', 'perch-update',
                         'release-common.sh', 'VERSION']:
                content = (version if name == 'VERSION' else 'content').encode()
                entry = tarfile.TarInfo('./' + name)
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
            if bad_member:
                entry = tarfile.TarInfo(bad_member)
                if symlink:
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = '/etc/passwd'
                tar.addfile(entry)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.path / 'SHA256SUMS').write_text(digest + '  perch-x86_64-unknown-linux-musl.tar.gz\n')

    def download(self):
        return self.shell('scripts/release-common.sh', '''
            curl() { local out='' url; while (($#)); do
                if [[ $1 == --output ]]; then out=$2; shift; fi
                url=$1; shift
              done
              case "$url" in
                */SHA256SUMS) cp "$PWD/SHA256SUMS" "$out" ;;
                *) cp "$PWD/release.tar.gz" "$out" ;;
              esac
            }
            perch_download "$PWD/download" v0.1.0
        ''')

    def test_valid_archive_is_verified_and_extracted(self):
        self.archive()
        result = self.download()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'download/bundle/perch').read_text(), 'content')

    def test_modified_archive_fails_verification(self):
        self.archive()
        with (self.path / 'release.tar.gz').open('ab') as file:
            file.write(b'corruption')
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum', result.stderr.lower())
        self.assertFalse((self.path / 'download/bundle/perch').exists())

    def test_archive_cannot_escape_extraction_directory(self):
        self.archive(bad_member='../escaped')
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / 'download/escaped').exists())
        self.assertFalse((self.path / 'download/bundle/perch').exists())

    def test_archive_links_are_rejected(self):
        self.archive(bad_member='./LICENSE', symlink=True)
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('links', result.stderr)

    def test_wrong_release_version_is_rejected(self):
        self.archive(version='v0.2.0')
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('version', result.stderr)

    def test_no_release_fails_without_downloading_assets(self):
        result = self.shell('scripts/release-common.sh', '''
            curl() { printf 'https://github.com/olivecarney/perch/releases'; }
            perch_download "$PWD/download"
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Publish a version tag first', result.stderr)

    def test_latest_release_404_has_actionable_error(self):
        result = self.shell('scripts/release-common.sh', '''
            curl() { return 22; }
            perch_download "$PWD/download"
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('published release', result.stderr)

    def test_numeric_resource_validation(self):
        for value in ['0', '-1', '0256', '256,swap=999', '999999999999999999999999', 'abc']:
            result = self.shell('scripts/proxmox/install.sh',
                                f'perch_number RAM "{value}" 256 1048576')
            self.assertNotEqual(result.returncode, 0, value)
        result = self.shell('scripts/proxmox/install.sh', 'perch_number RAM 256 256 1048576')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_standalone_host_download_matches_bundle(self):
        def extract(path):
            text = (ROOT / path).read_text()
            return text.split('# BEGIN RELEASE DOWNLOAD')[1].split('# END RELEASE DOWNLOAD')[0]
        self.assertEqual(extract('scripts/release-common.sh'), extract('scripts/proxmox/install.sh'))

    def test_download_rejects_checksum_mismatch(self):
        result = self.shell('scripts/release-common.sh', '''
            curl() { local out=''; while (($#)); do
              if [[ $1 == --output ]]; then out=$2; shift; fi; shift; done
              printf corrupt > "$out"; }
            perch_download "$PWD/download" v0.1.0
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum', result.stderr.lower())
        self.assertFalse((self.path / 'download/bundle/perch').exists())

    def update(self, mode):
        (self.path / 'perch').write_text('previous-binary')
        (self.path / 'apps.json').write_text('[{"id":42}]')
        before = (self.path / 'apps.json').stat()
        result = self.shell('scripts/perch-update', f'''
            BINARY="$PWD/perch"
            STATE_DIR="$PWD/state"
            mkdir "$STATE_DIR"
            printf v0.1.0 > "$STATE_DIR/VERSION"
            perch_download() {{ mkdir -p "$1/bundle";
              printf next-binary > "$1/bundle/perch";
              printf v0.2.0 > "$1/bundle/VERSION";
              {"return 1" if mode == "download" else ":"}; }}
            systemctl() {{ printf '%s\\n' "$*" >> "$PWD/service.log";
              {'return 1' if mode == 'restart' else ':'}; }}
            perch_healthy() {{ {'return 1' if mode == 'health' else ':'}; }}
            perch_update v0.2.0
        ''')
        self.assertEqual((self.path / 'apps.json').read_text(), '[{"id":42}]')
        after = (self.path / 'apps.json').stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        return result

    def test_failed_download_leaves_running_service_alone(self):
        result = self.update('download')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.path / 'perch').read_text(), 'previous-binary')
        self.assertFalse((self.path / 'service.log').exists())

    def test_successful_update_replaces_binary(self):
        result = self.update('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / 'perch').read_text(), 'next-binary')
        self.assertEqual((self.path / 'state/VERSION').read_text().strip(), 'v0.2.0')

    def test_failed_health_rolls_back_binary_and_version(self):
        result = self.update('health')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.path / 'perch').read_text(), 'previous-binary')
        self.assertEqual((self.path / 'state/VERSION').read_text(), 'v0.1.0')
        self.assertGreaterEqual((self.path / 'service.log').read_text().count('restart perch'), 2)

    def test_failed_restart_rolls_back_binary(self):
        result = self.update('restart')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.path / 'perch').read_text(), 'previous-binary')

    def test_termination_during_restart_rolls_back(self):
        (self.path / 'perch').write_text('previous-binary')
        (self.path / 'apps.json').write_text('[{"id":42}]')
        result = self.shell('scripts/perch-update', '''
            BINARY="$PWD/perch"
            STATE_DIR="$PWD/state"
            mkdir "$STATE_DIR"
            printf v0.1.0 > "$STATE_DIR/VERSION"
            perch_download() { mkdir -p "$1/bundle";
              printf next-binary > "$1/bundle/perch";
              printf v0.2.0 > "$1/bundle/VERSION"; }
            systemctl() {
              if [[ $1 == restart && ! -f $PWD/signalled ]]; then
                touch "$PWD/signalled"
                python3 -c 'import os,signal; os.kill(os.getppid(), signal.SIGTERM)'
              fi
            }
            perch_healthy() { :; }
            perch_update v0.2.0
        ''')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual((self.path / 'perch').read_text(), 'previous-binary')
        self.assertEqual((self.path / 'state/VERSION').read_text(), 'v0.1.0')
        self.assertEqual((self.path / 'apps.json').read_text(), '[{"id":42}]')

    def test_host_rejects_existing_id_before_create(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            pvesh() { return 1; }
            perch_assert_unused_id 101
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already', result.stderr)

    def test_created_ct_supports_service_sandbox_and_is_unprivileged(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            pvesh() { return 0; }
            pct() { printf '%s\\n' "$@" > "$PWD/arguments"; }
            perch_create_ct 101 local:vztmpl/debian.tar.zst --memory 256
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.path / 'arguments').read_text().splitlines()
        self.assertEqual(args[:3], ['create', '101', 'local:vztmpl/debian.tar.zst'])
        self.assertEqual(args[args.index('--unprivileged') + 1], '1')
        self.assertEqual(args[args.index('--features') + 1], 'nesting=1')
        self.assertEqual(args[args.index('--memory') + 1], '256')

    def test_create_cannot_touch_existing_container(self):
        result = self.shell('scripts/proxmox/install.sh', '''
            pvesh() { return 1; }
            pct() { touch "$PWD/touched-existing"; }
            perch_create_ct 101 local:vztmpl/debian.tar.zst
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / 'touched-existing').exists())

    def test_ipv4_validation(self):
        for value in ['192.168.1.5', '10.0.0.1', '0.0.0.0']:
            result = self.shell('scripts/proxmox/install.sh', f'perch_ipv4 "{value}"')
            self.assertEqual(result.returncode, 0, result.stderr)
        for value in ['256.1.1.1', '1.2.3', '1.2.3.4,bridge=evil', '1.2.3.04', 'a.b.c.d']:
            result = self.shell('scripts/proxmox/install.sh', f'perch_ipv4 "{value}"')
            self.assertNotEqual(result.returncode, 0, value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
