import { getText } from './fetch.mjs';

export async function fredSeries(name) {
  const body = await getText(`https://fred.stlouisfed.org/graph/fredgraph.csv?id=${encodeURIComponent(name)}`, { headers: { Accept: 'text/csv' } });
  const lines = body.trim().split('\n');
  if (lines.length < 2 || !lines[0].includes(',')) throw new Error(`Unexpected FRED response for ${name}`);
  const points = [];
  for (let index = 1; index < lines.length; index += 1) {
    const [date, raw] = lines[index].split(',');
    const value = Number(raw);
    if (Number.isFinite(value)) points.push({ date: date.trim(), value });
  }
  if (!points.length) throw new Error(`No numeric observations for ${name}`);
  return points;
}
