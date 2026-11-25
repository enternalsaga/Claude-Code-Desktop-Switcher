// Port of Get-SecretPatterns (src/Harness.Core.ps1). Order matters: whole blocks
// and specific tokens first, KEY=value rules last.
const SECRET_PATTERNS = [
  {
    regex: /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/gis,
    replacement: '[REDACTED]',
  },
  {
    regex: /-----BEGIN [A-Z ]*PRIVATE KEY-----/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /sk-[A-Za-z0-9_-]{20,}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /gh[po]_[A-Za-z0-9]{20,}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /github_pat_[A-Za-z0-9_]{20,}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /AKIA[0-9A-Z]{16}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /xox[abp]-[A-Za-z0-9-]{10,}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /AIza[0-9A-Za-z_-]{35}/gi,
    replacement: '[REDACTED]',
  },
  {
    regex: /Bearer\s+[A-Za-z0-9._~+/=-]{16,}/gi,
    replacement: 'Bearer [REDACTED]',
  },
  // PowerShell uses (?im) with inline (?-i:...) for uppercase env var names; JS has no inline
  // flag toggling, so [Ee][Xx][Pp][Oo][Rr][Tt] and \[[Rr]...\] are explicit without /i.
  {
    regex: /^(?<pre>[ \t]*(?:[Ee][Xx][Pp][Oo][Rr][Tt][ \t]+)?[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*[ \t]*=[ \t]*)(?!\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd]\])\S[^\r\n]*/gm,
    replacement: '$<pre>[REDACTED]',
  },
  {
    regex: /(?<![A-Za-z0-9_])(?<pre>[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Z0-9_]*=)(?!\[[Rr][Ee][Dd][Aa][Cc][Tt][Ee][Dd]\])(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s"']+)/g,
    replacement: '$<pre>[REDACTED]',
  },
  {
    regex: /(?<pre>"[A-Za-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key|apikey)"\s*:\s*)"(?!\[REDACTED\]")(?:[^"\\\r\n]|\\.)*"/gi,
    replacement: '$<pre>"[REDACTED]"',
  },
  {
    regex: /(?<![A-Za-z0-9_])(?<pre>--?[A-Za-z0-9_-]*(?:password|passwd|secret|token|api[_-]?key|apikey)=)(?!\[REDACTED\])(?:"[^"\r\n]*"|'[^'\r\n]*'|\S+)/gi,
    replacement: '$<pre>[REDACTED]',
  },
];

export function redact(text) {
  if (!text) return text;
  let out = String(text);
  for (const { regex, replacement } of SECRET_PATTERNS) {
    regex.lastIndex = 0;
    out = out.replace(regex, replacement);
  }
  return out;
}
