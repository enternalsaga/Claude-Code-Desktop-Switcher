import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { redact } from '../redact.mjs';

const samplesUrl = new URL('../../../tests/fixtures/xharness/secret-samples.json', import.meta.url);
const samples = JSON.parse(fs.readFileSync(samplesUrl, 'utf8'));

test('matches every PowerShell sample', () => {
  for (const s of samples) {
    assert.equal(redact(s.in), s.out, s.in);
  }
});

test('empty and null pass through', () => {
  assert.equal(redact(''), '');
  assert.equal(redact(null), null);
});
