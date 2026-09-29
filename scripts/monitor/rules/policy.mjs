import { getJson } from '../fetch.mjs';

export const id = 'policy';

const cutoff = 3 * 86400000;

async function executiveOrders(events, failures) {
  try {
    const url = new URL('https://www.federalregister.gov/api/v1/documents.json');
    url.searchParams.set('per_page', '10');
    url.searchParams.set('order', 'newest');
    url.searchParams.append('conditions[presidential_document_type][]', 'executive_order');
    for (const field of ['title', 'html_url', 'publication_date', 'signing_date', 'executive_order_number', 'document_number', 'abstract']) url.searchParams.append('fields[]', field);
    const feed = await getJson(url);
    for (const document of feed.results ?? []) {
      const published = Date.parse(`${document.signing_date ?? document.publication_date}T12:00:00Z`);
      if (!Number.isFinite(published) || Date.now() - published > cutoff) continue;
      events.push({
        key: `policy:eo:${document.document_number}`,
        title: `Executive Order ${document.executive_order_number ?? ''}: ${document.title}`.replace(': ', document.executive_order_number ? ': ' : ' '),
        summary: (document.abstract ?? `The Federal Register published Executive Order ${document.executive_order_number ?? ''} signed ${document.signing_date ?? document.publication_date}.`).slice(0, 1200),
        source: 'Federal Register',
        url: document.html_url,
        published_at: new Date(published).toISOString(),
        category: 'politics',
        priority: 'urgent',
        tickers: [],
        tags: ['deterministic', 'executive-order'],
      });
    }
  } catch (error) {
    failures.push(`federal-register-eo: ${error.message}`);
  }
}

async function significantRules(events, failures) {
  try {
    const url = new URL('https://www.federalregister.gov/api/v1/documents.json');
    url.searchParams.set('per_page', '20');
    url.searchParams.set('order', 'newest');
    url.searchParams.append('conditions[type][]', 'RULE');
    url.searchParams.append('conditions[significant]', '1');
    for (const field of ['title', 'html_url', 'publication_date', 'document_number', 'agencies', 'abstract']) url.searchParams.append('fields[]', field);
    const feed = await getJson(url);
    for (const document of (feed.results ?? []).slice(0, 5)) {
      const published = Date.parse(`${document.publication_date}T12:00:00Z`);
      if (!Number.isFinite(published) || Date.now() - published > cutoff) continue;
      const agency = document.agencies?.[0]?.name ?? 'A federal agency';
      events.push({
        key: `policy:rule:${document.document_number}`,
        title: `${agency} issues a significant final rule: ${document.title}`.slice(0, 300),
        summary: (document.abstract ?? `${agency} published a significant final rule in the Federal Register on ${document.publication_date}.`).slice(0, 1200),
        source: 'Federal Register',
        url: document.html_url,
        published_at: new Date(published).toISOString(),
        category: 'politics',
        priority: 'normal',
        tickers: [],
        tags: ['deterministic', 'regulation'],
      });
    }
  } catch (error) {
    failures.push(`federal-register-rule: ${error.message}`);
  }
}

export async function run() {
  const events = [];
  const failures = [];
  await Promise.all([executiveOrders(events, failures), significantRules(events, failures)]);
  return { events, failures };
}
