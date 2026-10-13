import { test } from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const bundle = async entry => import(`data:text/javascript,${encodeURIComponent((await build({ entryPoints: [entry], bundle: true, format: 'esm', write: false })).outputFiles[0].text)}`);
const { parseFiling, periods, search, pages } = await bundle('src/filings.ts');

test('filing HTML becomes headings, paragraphs and clean financial tables', () => {
  const html = `<html><head><title>nvda-20260726</title></head><body><div style="display:none"><ix:header><ix:hidden>secret</ix:hidden></ix:header></div>
    <p>EX-99.1 2 q2fy27pr.htm EX-99.1</p>
    <div><span style="font-weight:700">NVIDIA CORP</span><span style="font-weight:700">ORATION</span></div>
    <div><span style="font-weight:bold">Data Center</span></div>
    <p>Revenue was a record, driven by demand for</p><p>accelerated computing.</p>
    <table><tr><td></td><td colspan="3">Three Months Ended</td><td colspan="3">Six Months Ended</td></tr>
      <tr><td>Revenue</td><td>$</td><td><ix:nonFraction>96,221</ix:nonFraction></td><td></td><td>$</td><td>46,743</td><td>177,837</td><td>90,805</td></tr>
      <tr><td>Other income (expense)</td><td>(</td><td>102</td><td>)</td><td>12</td><td>%</td><td>1</td><td>2</td></tr></table>
    <table><tr><td>•</td><td>Revenue of $96.2 billion, up 106% from a year ago</td></tr></table>
    <p><span>•</span><span>Gaming revenue rose</span></p>
    <p>17</p></body></html>`;
  const { blocks } = parseFiling(html);
  assert.deepEqual(blocks.map(b => b.kind), ['heading', 'heading', 'paragraph', 'table', 'paragraph', 'paragraph']);
  assert.equal(blocks[0].text, 'NVIDIA CORPORATION');
  assert.equal(blocks[2].text, 'Revenue was a record, driven by demand for accelerated computing.');
  assert.deepEqual(blocks[3].rows, [['', 'Three Months Ended', '', 'Six Months Ended', ''], ['Revenue', '$96,221', '$46,743', '177,837', '90,805'], ['Other income (expense)', '(102)', '12%', '1', '2']]);
  assert.equal(blocks[4].text, '• Revenue of $96.2 billion, up 106% from a year ago');
  assert.equal(blocks[5].text, '• Gaming revenue rose');
  assert.equal(JSON.stringify(blocks).includes('secret'), false);
  assert.deepEqual(search(blocks, 'revenue data center').map(hit => hit.index), [2, 3, 4, 5]);
  assert.deepEqual(pages(blocks), [0]);
});

test('XBRL periods keep recast values, original filings and a derived fourth quarter', () => {
  const fact = (start, end, val, accn, filed) => ({ start, end, val, accn, filed, form: '10-Q' });
  const facts = [
    fact('2025-01-27', '2025-04-27', 10, 'q1', '2025-05-20'), fact('2025-04-28', '2025-07-27', 20, 'q2', '2025-08-20'),
    fact('2025-07-28', '2025-10-26', 30, 'q3', '2025-11-19'), { ...fact('2025-01-27', '2026-01-25', 100, 'k', '2026-02-25'), form: '10-K' },
    fact('2025-04-28', '2025-07-27', 21, 'q2-next', '2026-08-26'),
  ];
  const { quarters, years } = periods(facts);
  assert.equal(years.length, 1);
  assert.deepEqual(quarters.map(q => [q.end, q.val, q.original.accn, Boolean(q.derived)]), [
    ['2025-04-27', 10, 'q1', false], ['2025-07-27', 21, 'q2', false], ['2025-10-26', 30, 'q3', false], ['2026-01-25', 39, 'k', true],
  ]);
});
