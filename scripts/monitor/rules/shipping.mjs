import { getJson } from '../fetch.mjs';

export const id = 'shipping';

const watched = ['Strait of Hormuz', 'Suez Canal', 'Bab el-Mandeb Strait', 'Panama Canal', 'Malacca Strait', 'Bosporus Strait', 'Taiwan Strait', 'Cape of Good Hope'];
const average = values => values.reduce((sum, value) => sum + value, 0) / (values.length || 1);

export function shifts(records, now = Date.now()) {
  const byName = new Map();
  for (const record of records) {
    const name = String(record.portname);
    if (!watched.includes(name)) continue;
    const date = typeof record.date === 'number' ? new Date(record.date).toISOString().slice(0, 10) : String(record.date).slice(0, 10);
    byName.set(name, [...(byName.get(name) ?? []), { date, total: Number(record.n_total), tanker: Number(record.n_tanker) }]);
  }
  const events = [];
  for (const [name, list] of byName) {
    const days = list.sort((a, b) => a.date.localeCompare(b.date));
    if (days.length < 30) continue;
    const week = days.slice(-7), prior = days.slice(-37, -7);
    const recent = average(week.map(day => day.total)), base = average(prior.map(day => day.total));
    if (base < 3) continue;
    const change = (recent / base - 1) * 100;
    if (change > -30 && change < 40) continue;
    const latest = days.at(-1).date;
    const bucket = Math.trunc(change / 10) * 10;
    const tankers = average(week.map(day => day.tanker));
    events.push({
      key: `shipping:${name}:${latest.slice(0, 7)}:${bucket}`,
      title: `${name} transits ${change < 0 ? 'down' : 'up'} ${Math.abs(Math.round(change))}% from their 30-day average`,
      summary: `Ships passing through the ${name} averaged ${recent.toFixed(1)} a day over the week to ${latest}, against ${base.toFixed(1)} a day over the previous 30 days, including ${tankers.toFixed(1)} tankers a day. Counts come from IMF PortWatch satellite AIS tracking, which can be revised as late position reports arrive.`,
      source: 'IMF PortWatch',
      url: 'https://portwatch.imf.org/pages/chokepoints',
      published_at: `${latest}T12:00:00Z`,
      category: 'world',
      priority: Math.abs(change) >= 50 && ['Strait of Hormuz', 'Suez Canal', 'Bab el-Mandeb Strait'].includes(name) ? 'urgent' : 'normal',
      tickers: [],
      tags: ['deterministic', 'shipping', 'chokepoints', 'supply-chain'],
    });
  }
  return events;
}

export async function run() {
  const since = new Date(Date.now() - 45 * 86400000).toISOString().slice(0, 10);
  const feed = await getJson(`https://services9.arcgis.com/weJ1QsnbMYJlCHdG/arcgis/rest/services/Daily_Chokepoints_Data/FeatureServer/0/query?where=${encodeURIComponent(`date >= DATE '${since}'`)}&outFields=date,portname,n_total,n_tanker&orderByFields=date%20DESC&resultRecordCount=2000&f=json`, { timeout: 30000 });
  if (feed.error) throw new Error(`PortWatch: ${feed.error.message ?? 'query failed'}`);
  return { events: shifts((feed.features ?? []).map(feature => feature.attributes)), failures: [] };
}
