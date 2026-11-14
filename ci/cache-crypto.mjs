// HermesBuild streaming authenticated cache encryption; never cache plaintext DerivedData.
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream, openSync, readSync, writeFileSync, appendFileSync, closeSync, statSync, rmSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
const MAGIC = Buffer.from('HERMCD01');
const SALT_SIZE = 16, NONCE_SIZE = 12, TAG_SIZE = 16;
const HEADER_SIZE = MAGIC.length + SALT_SIZE + NONCE_SIZE;
const AAD = Buffer.from('HermesBuild:DerivedData:macos15:xcode26.3:ios26.2:arm64:v1');
const [mode, input, output] = process.argv.slice(2);
const token = process.env.HERMESSHELL_CACHE_TOKEN;
if (!token || token.length < 32) throw new Error('Missing scoped cache token');
if (!input || !output || !['encrypt','decrypt'].includes(mode)) throw new Error('Usage: encrypt|decrypt input output');
const keyFrom = (salt) => Buffer.from(hkdfSync('sha256', Buffer.from(token, 'utf8'), salt, AAD, 32));
try {
  if (mode === 'encrypt') {
    const salt = randomBytes(SALT_SIZE), nonce = randomBytes(NONCE_SIZE);
    const key = keyFrom(salt), cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(AAD);
    writeFileSync(output, Buffer.concat([MAGIC, salt, nonce]), { mode: 0o600 });
    await pipeline(createReadStream(input), cipher, createWriteStream(output, { flags: 'a', mode: 0o600 }));
    appendFileSync(output, cipher.getAuthTag());
    key.fill(0);
  } else {
    const length = statSync(input).size;
    if (length < HEADER_SIZE + TAG_SIZE) throw new Error('Truncated encrypted cache');
    const fd = openSync(input, 'r'), header = Buffer.alloc(HEADER_SIZE), tag = Buffer.alloc(TAG_SIZE);
    try {
      if (readSync(fd, header, 0, HEADER_SIZE, 0) !== HEADER_SIZE ||
          readSync(fd, tag, 0, TAG_SIZE, length - TAG_SIZE) !== TAG_SIZE) throw new Error('Encrypted cache read failed');
    } finally { closeSync(fd); }
    if (!header.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error('Unexpected cache format');
    const salt = header.subarray(MAGIC.length, MAGIC.length + SALT_SIZE);
    const nonce = header.subarray(MAGIC.length + SALT_SIZE);
    const key = keyFrom(salt), decipher = createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAAD(AAD);
    decipher.setAuthTag(tag);
    await pipeline(
      createReadStream(input, { start: HEADER_SIZE, end: length - TAG_SIZE - 1 }),
      decipher,
      createWriteStream(output, { flags: 'wx', mode: 0o600 })
    );
    key.fill(0);
  }
  console.log('CACHE_CRYPTO_' + mode.toUpperCase() + '_OK bytes=' + statSync(output).size);
} catch (error) {
  rmSync(output, { force: true });
  throw new Error('Authenticated cache ' + mode + ' failed: ' + error.message);
}
