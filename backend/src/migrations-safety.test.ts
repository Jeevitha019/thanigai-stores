import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { deepStrictEqual, equal, match, ok } from 'node:assert/strict';
import { it } from 'node:test';

it('keeps shipped schema migrations versioned and non-destructive', async () => {
  const directory = path.resolve(__dirname, '../migrations');
  const files = (await readdir(directory))
    .filter((file) => /^\d+_[a-z0-9_-]+\.sql$/i.test(file))
    .sort();

  ok(files.length > 0);
  const versions = files.map((file) => Number(file.split('_', 1)[0]));
  deepStrictEqual(
    versions,
    Array.from({ length: files.length }, (_, index) => index + 1),
  );

  for (const file of files) {
    const sql = await readFile(path.join(directory, file), 'utf8');
    equal(
      /(?:^|;)\s*(?:DROP\s+(?:TABLE|SCHEMA|DATABASE|COLUMN)\b|TRUNCATE\b|DELETE\s+FROM\b)/im.test(sql),
      false,
      file,
    );
    match(file, /^\d+_[a-z0-9_-]+\.sql$/i);
  }
});
