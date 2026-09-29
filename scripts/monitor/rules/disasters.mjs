import { getJson } from '../fetch.mjs';

export const id = 'disasters';

export async function run() {
  const events = [];
  const failures = [];
  try {
    const feed = await getJson('https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson');
    for (const feature of feed.features ?? []) {
      const { mag, place, url, time, tsunami, title } = feature.properties ?? {};
      if (typeof mag !== 'number' || mag < 6 || !url || !time) continue;
      events.push({
        key: `disasters:quake:${feature.id}`,
        title: `Magnitude ${mag.toFixed(1)} earthquake strikes ${place ?? 'an unspecified region'}`,
        summary: `The USGS reports a magnitude ${mag.toFixed(1)} earthquake ${place ? `at ${place}` : ''}${tsunami ? ', with a tsunami evaluation flagged for the region' : ''}. ${title ?? ''}`.trim(),
        source: 'US Geological Survey',
        url,
        published_at: new Date(time).toISOString(),
        category: 'world',
        priority: mag >= 7 ? 'breaking' : 'urgent',
        tickers: [],
        tags: ['deterministic', 'earthquake'],
      });
    }
  } catch (error) {
    failures.push(`usgs: ${error.message}`);
  }
  return { events, failures };
}
