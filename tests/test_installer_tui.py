"""Real whiptail in a PTY, with PVE effects replaced by deterministic test data."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('whiptail'), 'whiptail is installed by Linux CI')
class InstallerDialogs(unittest.TestCase):
    def run_dialog(self, actions):
        code = '''
            source "$1"
            pvesh() { printf 123; }
            perch_bridges() { printf 'vmbr0\\n'; }
            nproc() { printf 4; }
            roots=local-lvm templates=local DEFAULTS_FILE=/nonexistent/perch-test-defaults
            PERCH_UI=dialog
            exec 3</dev/tty
            perch_set_defaults
            if perch_choose_settings; then printf '\\nRESULT=CONFIRMED\\n'; else printf '\\nRESULT=CANCELLED\\n'; fi
        '''
        pid, fd = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm'
            os.execvp('bash', ['bash', '-c', code, 'test', str(ROOT / 'scripts/proxmox/install.sh')])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 110, 0, 0))
        output = b''
        deadline = time.monotonic() + 20
        pending = list(actions)
        status = None
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], .1)[0]:
                    try:
                        block = os.read(fd, 65536)
                    except OSError:
                        _, status = os.waitpid(pid, 0)
                        break
                    if not block:
                        _, status = os.waitpid(pid, 0)
                        break
                    output += block
                if pending and pending[0][0] in output:
                    _, keys = pending.pop(0)
                    os.write(fd, keys)
                done, value = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = value
                    break
            if status is None:
                done, value = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = value
                else:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                    self.fail(f'Dialog timed out with pending actions {pending}: {output[-3000:]!r}')
            # Reap status may become available before the final output is drained.
            while select.select([fd], [], [], .1)[0]:
                try:
                    block = os.read(fd, 65536)
                except OSError:
                    break
                if not block:
                    break
                output += block
        finally:
            os.close(fd)
        self.assertEqual(status, 0, output[-3000:].decode(errors='replace'))
        return output

    def test_default_install_and_review_confirmation(self):
        output = self.run_dialog([
            (b'Choose an installation mode', b'\r'),
            (b'Create unprivileged', b'\x1b[D\r'),
        ])
        self.assertIn(b'RESULT=CONFIRMED', output)

    def test_exit_from_mode_menu(self):
        output = self.run_dialog([(b'Choose an installation mode', b'\x1b')])
        self.assertIn(b'RESULT=CANCELLED', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
