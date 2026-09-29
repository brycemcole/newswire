import { getJson, getText } from '../fetch.mjs';

export const id = 'infrastructure';

const providers = [
  { name: 'Cloudflare', host: 'www.cloudflarestatus.com' },
  { name: 'GitHub', host: 'www.githubstatus.com' },
  { name: 'Anthropic', host: 'status.claude.com' },
  { name: 'Atlassian', host: 'status.atlassian.com' },
  { name: 'Zoom', host: 'status.zoom.us' },
  { name: 'Digital Ocean', host: 'status.digitalocean.com' },
];

async function outages(events, failures) {
  const checks = providers.map(async provider => {
    const feed = await getJson(`https://${provider.host}/api/v2/incidents/unresolved.json`, { timeout: 10000 });
    for (const incident of feed.incidents ?? []) {
      if (!['critical', 'major'].includes(incident.impact)) continue;
      events.push({
        key: `infrastructure:outage:${provider.name}:${incident.id}`,
        title: `${provider.name} reports a ${incident.impact} service incident: ${incident.name}`.slice(0, 300),
        summary: `${provider.name} status is reporting "${incident.name}" with ${incident.impact} impact, currently ${incident.status.replace('_', ' ')}. ${(incident.incident_updates?.[0]?.body ?? '').slice(0, 800)}`.trim(),
        source: `${provider.name} Status`,
        url: incident.shortlink ?? `https://${provider.host}`,
        published_at: incident.created_at ? new Date(incident.created_at).toISOString() : undefined,
        category: 'technology',
        priority: incident.impact === 'critical' ? 'urgent' : 'normal',
        tickers: [],
        tags: ['deterministic', 'outage'],
      });
    }
  });
  const settled = await Promise.allSettled(checks);
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`status ${providers[index].name}: ${entry.reason?.message ?? entry.reason}`); });
}

async function exploitedVulnerabilities(events, failures) {
  try {
    const feed = await getJson('https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json', { timeout: 25000 });
    const today = new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10);
    const fresh = (feed.vulnerabilities ?? []).filter(entry => entry.dateAdded >= today);
    for (const entry of fresh.slice(0, 5)) {
      events.push({
        key: `infrastructure:kev:${entry.cveID}`,
        title: `CISA adds ${entry.cveID} to its known exploited vulnerabilities catalog`,
        summary: `CISA listed ${entry.cveID} (${entry.vendorProject} ${entry.product}) as actively exploited on ${entry.dateAdded}, with required action "${entry.requiredAction}" due ${entry.dueDate}.`.slice(0, 1200),
        source: 'CISA',
        url: 'https://www.cisa.gov/known-exploited-vulnerabilities-catalog',
        published_at: `${entry.dateAdded}T12:00:00Z`,
        category: 'technology',
        priority: entry.knownRansomwareCampaignUse === 'Known' ? 'urgent' : 'normal',
        tickers: [],
        tags: ['deterministic', 'cyber', 'cve'],
      });
    }
  } catch (error) {
    failures.push(`cisa-kev: ${error.message}`);
  }
}

async function groundStops(events, failures) {
  try {
    const body = await getText('https://nasstatus.faa.gov/api/airport-status-information', { timeout: 12000 });
    const section = /<Name>Ground Stop Programs<\/Name>([\s\S]*?)<\/Delay_type>/.exec(body);
    if (!section) return;
    const airports = [...section[1].matchAll(/<ARPT>([A-Z]{3})<\/ARPT>[\s\S]*?<Reason>([^<]*)<\/Reason>/g)];
    if (!airports.length) return;
    const stamp = /<Update_Time>([^<]+)<\/Update_Time>/.exec(body)?.[1] ?? '';
    const list = airports.map(match => match[1]);
    events.push({
      key: `infrastructure:groundstop:${list.join('-')}:${new Date().toISOString().slice(0, 13)}`,
      title: `FAA reports ground stops at ${list.join(', ')}`,
      summary: `The FAA national airspace status page lists active ground stop programs at ${list.join(', ')}. Reason given: ${airports[0][2]}. Status as of ${stamp}.`.slice(0, 1200),
      source: 'FAA',
      url: 'https://nasstatus.faa.gov/',
      category: 'general',
      priority: list.length >= 3 ? 'urgent' : 'normal',
      tickers: [],
      tags: ['deterministic', 'aviation'],
    });
  } catch (error) {
    failures.push(`faa: ${error.message}`);
  }
}

export async function run() {
  const events = [];
  const failures = [];
  await Promise.all([outages(events, failures), exploitedVulnerabilities(events, failures), groundStops(events, failures)]);
  return { events, failures };
}
