import test from 'node:test';
import assert from 'node:assert/strict';
import { logoCandidates } from '../public/logos.mjs';

test('automatic logos use the service origin, port, and subpath without a third-party service', () => {
  assert.deepEqual(logoCandidates({address:'http://192.168.1.5:8080/admin/',logo:'auto'}), [
    'http://192.168.1.5:8080/admin/favicon.ico',
    'http://192.168.1.5:8080/favicon.ico',
    'http://192.168.1.5:8080/favicon.svg',
    'http://192.168.1.5:8080/apple-touch-icon.png',
  ]);
});
test('root URLs do not request the same favicon twice', () => {
  assert.deepEqual(logoCandidates({address:'https://nas.local/',logo:'auto'}), [
    'https://nas.local/favicon.ico','https://nas.local/favicon.svg','https://nas.local/apple-touch-icon.png',
  ]);
});
test('explicit remote logos and uploads are used directly', () => {
  for (const logo of ['https://icons.example/nas.svg','data:image/png;base64,AAAA']) {
    assert.deepEqual(logoCandidates({address:'https://nas.local/',logo}), [logo]);
  }
});
test('bundled logos stay local', () => {
  assert.deepEqual(logoCandidates({address:'http://nas.local',logo:'truenas'}), ['/icons/truenas.svg?v=1']);
});
