import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, rm, symlink, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';
import {uploadReleaseArtifacts} from '../scripts/upload-release-artifacts.mjs';

async function fixture(context) {
  const output = fileURLToPath(new URL('../../build/caihong-artifact-tests/', import.meta.url));
  await mkdir(output, {recursive: true});
  const directory = await mkdtemp(join(output, 'upload-'));
  context.after(() => rm(directory, {recursive: true, force: true}));
  const calls = [];
  const client = {
    async uploadArtifact(...args) {
      calls.push(args);
      return {id: calls.length, digest: 'test-digest'};
    },
  };
  return {directory, calls, client};
}

test('each release file is uploaded independently without ZIP wrapping', async context => {
  const {directory, calls, client} = await fixture(context);
  const names = [
    'caihong-boot-linux-test.img',
    'caihong-platform-archlinuxarm-test.tar.zst',
    'caihong-rootfs-test.ext4.sparse.img.zst.part01',
    'caihong-rootfs-test.ext4.sparse.img.zst.part02',
  ];
  for (const name of names) {
    await writeFile(join(directory, name), `contents of ${name}`);
  }
  const result = await uploadReleaseArtifacts(client, directory);
  assert.deepEqual(result.map(artifact => artifact.name), names);
  assert.equal(calls.length, names.length);
  for (const [index, name] of names.entries()) {
    assert.deepEqual(calls[index], [name, [join(directory, name)], directory, {
      retentionDays: 3,
      skipArchive: true,
    }]);
    assert.equal(await readFile(join(directory, name), 'utf8'), `contents of ${name}`);
  }
});

test('an empty assets directory fails instead of silently skipping uploads', async context => {
  const {directory, calls, client} = await fixture(context);
  await assert.rejects(uploadReleaseArtifacts(client, directory), /No release assets/);
  assert.equal(calls.length, 0);
});

test('directories are rejected before uploading any file', async context => {
  const {directory, calls, client} = await fixture(context);
  await writeFile(join(directory, 'boot.img'), 'boot');
  await mkdir(join(directory, 'unexpected'));
  await assert.rejects(uploadReleaseArtifacts(client, directory), /Unexpected release asset/);
  assert.equal(calls.length, 0);
});

test('symlinks cannot publish files outside the release assets directory', async context => {
  const {directory, calls, client} = await fixture(context);
  await symlink('../outside', join(directory, 'linked.img'));
  await assert.rejects(uploadReleaseArtifacts(client, directory), /Unexpected release asset/);
  assert.equal(calls.length, 0);
});

test('hidden files are not uploaded', async context => {
  const {directory, calls, client} = await fixture(context);
  await writeFile(join(directory, '.private'), 'private');
  await assert.rejects(uploadReleaseArtifacts(client, directory), /Unexpected release asset/);
  assert.equal(calls.length, 0);
});

test('an upload failure stops publication and is propagated', async context => {
  const {directory, calls, client} = await fixture(context);
  await writeFile(join(directory, 'boot.img'), 'boot');
  client.uploadArtifact = async (...args) => {
    calls.push(args);
    throw new Error('upload failed');
  };
  await assert.rejects(uploadReleaseArtifacts(client, directory), /upload failed/);
  assert.equal(calls.length, 1);
});

test('an incomplete upload response is not reported as success', async context => {
  const {directory, client} = await fixture(context);
  await writeFile(join(directory, 'boot.img'), 'boot');
  client.uploadArtifact = async () => ({});
  await assert.rejects(uploadReleaseArtifacts(client, directory), /No artifact ID returned/);
});
