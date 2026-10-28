import { test } from 'node:test';
import assert from 'node:assert/strict';
import { prBody, prompt } from '../../scripts/feedback/run.mjs';

const report = { id: '0f6c3f5e-1111-4222-8333-444455556666', kind: 'bug', note: 'Chart goes blank\nafter rotating', context: { build: '88', os: 'iOS 26.1' }, image_count: 2 };

test('agent prompt carries the report, context and screenshot paths with the repo rules', () => {
  const text = prompt(report, ['/tmp/a/1.jpg', '/tmp/a/2.jpg']);
  assert.match(text, /bug report/);
  assert.match(text, /> Chart goes blank\n> after rotating/);
  assert.match(text, /- build: 88/);
  assert.match(text, /- \/tmp\/a\/2\.jpg/);
  assert.match(text, /cannot build or run the iOS app/);
  assert.match(text, /Do not commit, push/);
  assert.match(prompt({ ...report, kind: 'feature' }, []), /Implement the requested feature[\s\S]*|No screenshots were attached/);
});

test('pull request body quotes the report and the agent summary', () => {
  const body = prBody(report, 'Fixed the resize handler.');
  assert.match(body, /^## Bug report from the app/);
  assert.match(body, /> Chart goes blank/);
  assert.match(body, /2 screenshots · report 0f6c3f5e/);
  assert.match(body, /Fixed the resize handler\./);
});
