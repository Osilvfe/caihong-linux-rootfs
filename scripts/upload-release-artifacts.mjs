import {readdir} from 'node:fs/promises';
import {join, resolve} from 'node:path';

export async function uploadReleaseArtifacts(client, directory) {
  const root = resolve(directory);
  const entries = await readdir(root, {withFileTypes: true});
  if (entries.length === 0) {
    throw new Error('No release assets found');
  }
  for (const entry of entries) {
    if (!entry.isFile() || entry.name.startsWith('.')) {
      throw new Error(`Unexpected release asset: ${entry.name}`);
    }
  }

  const uploaded = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const result = await client.uploadArtifact(entry.name, [join(root, entry.name)], root, {
      retentionDays: 3,
      skipArchive: true,
    });
    if (!result.id) {
      throw new Error(`No artifact ID returned for ${entry.name}`);
    }
    uploaded.push({name: entry.name, ...result});
  }
  return uploaded;
}
