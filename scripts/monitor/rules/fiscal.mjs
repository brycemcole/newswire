import { getJson } from '../fetch.mjs';
import { fredSeries } from '../fetch_series.mjs';
import { signed } from '../fetch.mjs';

export const id = 'fiscal';

const treasury = 'https://api.fiscaldata.treasury.gov/services/api/fiscal_service';
const trillions = value => (value / 1e12).toFixed(3);
const billions = value => (value / 1e9).toLocaleString('en-US', { maximumFractionDigits: 1 });

async function nationalDebt(events) {
  const feed = await getJson(`${treasury}/v2/accounting/od/debt_to_penny?sort=-record_date&page%5Bsize%5D=400`, { timeout: 25000 });
  const rows = (feed.data ?? []).map(row => ({ date: row.record_date, total: Number(row.tot_pub_debt_out_amt), public: Number(row.debt_held_public_amt) })).filter(row => Number.isFinite(row.total));
  const latest = rows[0];
  if (!latest) return;

  const milestone = Math.floor(latest.total / 1e12);
  const crossed = rows.find(row => Math.floor(row.total / 1e12) < milestone);
  if (crossed) {
    events.push({
      key: `fiscal:debt-milestone:${milestone}`,
      title: `US national debt passes $${milestone} trillion`,
      summary: `Total public debt outstanding reached $${trillions(latest.total)} trillion on ${latest.date}, crossing the $${milestone} trillion mark from $${trillions(crossed.total)} trillion on ${crossed.date}. Figures are the Treasury\u2019s Debt to the Penny series.`,
      source: 'US Treasury Fiscal Data',
      url: 'https://fiscaldata.treasury.gov/datasets/debt-to-the-penny/debt-to-the-penny',
      published_at: `${latest.date}T18:00:00Z`,
      category: 'economy',
      priority: 'breaking',
      tickers: [],
      tags: ['deterministic', 'debt', 'fiscal'],
    });
  }

  const monthAgo = rows.find(row => Date.parse(latest.date) - Date.parse(row.date) >= 28 * 86400000);
  if (monthAgo) {
    const change = latest.total - monthAgo.total;
    if (Math.abs(change) >= 3e11) {
      events.push({
        key: `fiscal:debt-pace:${latest.date.slice(0, 7)}`,
        title: `US debt ${change >= 0 ? 'grew' : 'fell'} $${billions(Math.abs(change))} billion over the past month`,
        summary: `Total public debt outstanding stands at $${trillions(latest.total)} trillion as of ${latest.date}, a change of ${signed(change / 1e9, 1)} billion dollars from $${trillions(monthAgo.total)} trillion on ${monthAgo.date}. Of that total, $${trillions(latest.public)} trillion is debt held by the public. Treasury Debt to the Penny series.`,
        source: 'US Treasury Fiscal Data',
        url: 'https://fiscaldata.treasury.gov/datasets/debt-to-the-penny/debt-to-the-penny',
        published_at: `${latest.date}T18:00:00Z`,
        category: 'economy',
        priority: 'normal',
        tickers: [],
        tags: ['deterministic', 'debt', 'fiscal'],
      });
    }
  }
}

async function interestCost(events) {
  const feed = await getJson(`${treasury}/v2/accounting/od/interest_expense?sort=-record_date&page%5Bsize%5D=40`, { timeout: 25000 });
  const rows = feed.data ?? [];
  const latest = rows[0]?.record_date;
  if (!latest) return;
  const total = rows.filter(row => row.record_date === latest).reduce((sum, row) => sum + (Number(row.fytd_expense_amt) || 0), 0);
  if (!total) return;
  events.push({
    key: `fiscal:interest:${latest}`,
    title: `US interest costs reach $${trillions(total)} trillion so far this fiscal year`,
    summary: `Fiscal year-to-date interest expense on the public debt totals $${trillions(total)} trillion through ${latest}, summed across Treasury\u2019s reported security types. Source: Treasury Fiscal Data interest expense dataset.`,
    source: 'US Treasury Fiscal Data',
    url: 'https://fiscaldata.treasury.gov/datasets/interest-expense-debt-outstanding/interest-expense-on-the-public-debt-outstanding',
    published_at: `${latest}T18:00:00Z`,
    category: 'economy',
    priority: 'normal',
    tickers: [],
    tags: ['deterministic', 'debt', 'fiscal'],
  });
}

async function debtToGdp(events) {
  const [debt, gdp] = await Promise.all([fredSeries('GFDEBTN'), fredSeries('GDP')]);
  const latestDebt = debt.at(-1);
  const latestGdp = gdp.at(-1);
  if (!latestDebt || !latestGdp) return;
  const ratio = (latestDebt.value / 1000 / latestGdp.value) * 100;
  events.push({
    key: `fiscal:debt-to-gdp:${latestDebt.date}`,
    title: `US federal debt stands at ${ratio.toFixed(0)}% of GDP`,
    summary: `Federal debt of $${(latestDebt.value / 1e6).toFixed(2)} trillion for ${latestDebt.date} measured against annualized GDP of $${(latestGdp.value / 1000).toFixed(2)} trillion for ${latestGdp.date} gives a ratio of ${ratio.toFixed(1)}%. Computed from FRED series GFDEBTN and GDP, which are reported for different quarters.`,
    source: 'Federal Reserve Bank of St. Louis (FRED)',
    url: 'https://fred.stlouisfed.org/series/GFDEBTN',
    category: 'economy',
    priority: ratio >= 130 ? 'urgent' : 'normal',
    tickers: [],
    tags: ['deterministic', 'debt', 'fiscal'],
  });
}

async function worldDebt(events) {
  const economies = { USA: 'the United States', CHN: 'China', JPN: 'Japan', GBR: 'the United Kingdom', FRA: 'France', DEU: 'Germany', ITA: 'Italy', IND: 'India' };
  const feed = await getJson(`https://www.imf.org/external/datamapper/api/v1/GGXWDG_NGDP/${Object.keys(economies).join('/')}`, { timeout: 25000 });
  const values = feed.values?.GGXWDG_NGDP ?? {};
  const year = String(new Date().getUTCFullYear());
  const ranked = Object.entries(economies)
    .map(([code, name]) => ({ name, value: values[code]?.[year] }))
    .filter(entry => Number.isFinite(entry.value))
    .sort((a, b) => b.value - a.value);
  if (ranked.length < 4) return;
  const leader = ranked[0];
  events.push({
    key: `fiscal:world-debt:${year}`,
    title: `IMF projects ${leader.name} carries the heaviest debt load among major economies at ${leader.value.toFixed(0)}% of GDP`,
    summary: `IMF general government gross debt projections for ${year}: ${ranked.slice(0, 6).map(entry => `${entry.name} ${entry.value.toFixed(0)}%`).join(', ')}. Figures are IMF DataMapper projections of debt as a share of GDP, not settled outturns.`,
    source: 'International Monetary Fund',
    url: 'https://www.imf.org/external/datamapper/GGXWDG_NGDP@GDD',
    category: 'economy',
    priority: 'normal',
    tickers: [],
    tags: ['deterministic', 'debt', 'world-debt'],
  });
}

export async function run() {
  const events = [];
  const failures = [];
  const tasks = [nationalDebt, interestCost, debtToGdp, worldDebt];
  const settled = await Promise.allSettled(tasks.map(task => task(events)));
  settled.forEach((entry, index) => { if (entry.status === 'rejected') failures.push(`fiscal-${tasks[index].name}: ${entry.reason?.message ?? entry.reason}`); });
  return { events, failures };
}
