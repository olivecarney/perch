"""End-to-end checks against a disposable Perch process and data directory."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

BINARY = Path(os.environ.get('PERCH_BINARY', 'target/debug/perch')).resolve()

class PerchHTTP(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'apps.json'
        self.start()

    def start(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.base = f'http://127.0.0.1:{port}'
        self.process = subprocess.Popen([str(BINARY)], env={**os.environ, 'HOST':'127.0.0.1', 'PORT':str(port), 'PERCH_DATA':str(self.path)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                self.request()
                return
            except OSError:
                time.sleep(.03)
        raise RuntimeError('Perch did not start')

    def tearDown(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.temp.cleanup()

    def request(self, payload=None, headers=None, path='/api/apps'):
        request = urllib.request.Request(self.base+path, data=json.dumps(payload).encode() if payload else None, headers={'Content-Type':'application/json', **(headers or {})})
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.load(response)

    def app(self, **overrides):
        return {'id':0,'name':'NAS','address':'192.168.1.5:8080','description':'Files','category':'Storage','logo':'truenas','favorite':False, **overrides}

    def test_create_edit_restart_and_delete(self):
        self.assertEqual(self.request()[1], [])
        apps = self.request({'action':'save','app':self.app()})[1]
        self.assertEqual(apps[0]['address'], 'http://192.168.1.5:8080/')
        app = {**apps[0], 'name':'NAS edited', 'favorite':True}
        self.request({'action':'save','app':app})
        self.process.terminate(); self.process.wait(timeout=5)
        self.start()
        self.assertEqual(self.request()[1], [app])
        self.assertEqual(self.request({'action':'delete','id':app['id']})[1], [])
        self.assertEqual(json.loads(self.path.read_text()), [])

    def test_reorder_is_durable_and_rejects_stale_lists(self):
        first = self.request({'action':'save','app':self.app()})[1][0]
        second = self.request({'action':'save','app':self.app(name='Media')})[1][1]
        ordered = self.request({'action':'reorder','ids':[second['id'],first['id']]})[1]
        self.assertEqual(ordered, [second,first])
        self.process.terminate(); self.process.wait(timeout=5); self.start()
        self.assertEqual(self.request()[1], [second,first])
        for ids in [[first['id']], [first['id'],first['id']], [first['id'],999]]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request({'action':'reorder','ids':ids})
            self.assertEqual(error.exception.code,400)
        self.assertEqual(self.request()[1],[second,first])

    def test_rejects_unsafe_urls_and_cross_origin_writes(self):
        for payload, headers, expected in [
            ({'action':'save','app':self.app(address='javascript:alert(1)')}, {}, 400),
            ({'action':'save','app':self.app(logo='data:image/svg+xml;base64,PHN2Zz4=')}, {}, 400),
            ({'action':'delete','id':999}, {}, 404),
            ({'action':'save','app':self.app()}, {'Origin':'https://evil.example'}, 403),
            ({'action':'save','app':self.app(description='a'*65000)}, {}, 413),
        ]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request(payload, headers)
            self.assertEqual(error.exception.code, expected)
        self.assertEqual(self.request()[1], [])

    def test_failed_save_does_not_change_in_memory_apps(self):
        self.path.mkdir()
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request({'action':'save','app':self.app()})
        self.assertEqual(error.exception.code, 500)
        self.assertEqual(self.request()[1], [])

    def test_embedded_font(self):
        with urllib.request.urlopen(self.base+'/fonts/jetbrains-mono-v1.woff2') as response:
            self.assertEqual(response.headers['Content-Type'],'font/woff2')
            self.assertEqual(response.read(4),b'wOF2')
            self.assertIn('max-age=',response.headers['Cache-Control'])

    def test_static_assets_are_embedded(self):
        for path, content_type in [('/', 'text/html'),('/app.css','text/css'),('/app.js','text/javascript'),('/icons/jellyfin.svg','image/svg+xml')]:
            with urllib.request.urlopen(self.base+path) as response:
                self.assertIn(content_type,response.headers['Content-Type'])
                self.assertGreater(len(response.read()), 50)

if __name__ == '__main__':
    unittest.main(verbosity=2)
