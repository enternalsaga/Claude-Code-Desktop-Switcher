import { redact } from './redact.mjs';
import { readEntries } from './readers/common.mjs';

const [, , harness, file] = process.argv;
if (!harness || !file) {
  console.error('Usage: node dump.mjs <harness> <file>');
  process.exit(1);
}

const entries = await readEntries(harness, file);
const out = entries.map((e) => ({
  role: e.role,
  text: redact(e.text),
  tool: e.tool?.name ?? null,
}));
process.stdout.write(JSON.stringify(out) + '\n');
