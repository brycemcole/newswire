import type { calculatePulse } from './market-pulse';

type Pulse = ReturnType<typeof calculatePulse>;
export interface Driver {
  kind: 'price' | 'news' | 'data'; effect: 'lower' | 'higher'; points: number; title: string; detail: string;
  story_id?: string;
  stat?: { label: string; value: string; change: string }; channel?: string; url?: string; source?: string; at?: string; more?: number;
}

const names: Record<string, string> = { SPY: 'stocks', QQQ: 'tech stocks', XLE: 'energy stocks', DAL: 'airline stocks' };
const pct = (v: number | null, digits = 1) => v === null ? '' : `${v > 0 ? 'up' : 'down'} ${Math.abs(v).toFixed(digits)}%`;
const bp = (v: number | null) => v === null ? '' : `${v > 0 ? 'up' : 'down'} ${Math.abs(Math.round(v))} basis points`;
const signedPct = (v: number | null) => v === null ? '—' : `${v > 0 ? '+' : v < 0 ? '−' : ''}${Math.abs(v).toFixed(2)}%`;
const money = (v: number | null, prefix = '') => v === null ? '—' : prefix + v.toLocaleString('en-US', { maximumFractionDigits: v >= 1000 ? 0 : 2, minimumFractionDigits: v >= 1000 ? 0 : 2 });

type Input = NonNullable<Pulse['components']['market']>['inputs'][number];
function priceStory(i: Input, symbol: string): Pick<Driver, 'title' | 'detail' | 'stat'> {
  const d = i.change_day ?? i.change_hour ?? 0, up = d > 0;
  const energy = symbol === 'XLE', airline = symbol === 'DAL';
  switch (i.id) {
    case 'futures': return { title: `Stock futures are ${pct(d)} overnight`, detail: up ? 'Traders are already buying ahead of the open.' : 'Traders are already selling ahead of the open.', stat: { label: 'S&P 500 futures', value: money(i.price), change: signedPct(i.change_day) } };
    case 'oil': return { title: `Oil is ${pct(d)} since yesterday`, detail: energy ? (up ? 'Higher oil prices lift energy company profits.' : 'Cheaper oil cuts into energy company profits.')
      : airline ? (up ? 'Jet fuel is an airline\'s biggest cost after labor.' : 'Cheaper fuel is a direct saving for airlines.') : up ? 'Higher fuel costs squeeze company profits and consumer spending.' : 'Cheaper fuel eases costs for companies and consumers.',
      stat: { label: 'WTI crude, per barrel', value: money(i.price, '$'), change: signedPct(i.change_day) } };
    case 'vix': return { title: up ? 'Investors are buying protection' : 'Fear is fading', detail: `The VIX "fear gauge" is ${pct(d)}. ${up ? 'Traders expect bigger swings ahead.' : 'Traders expect calmer trading.'}`, stat: { label: 'VIX', value: money(i.price), change: signedPct(i.change_day) } };
    case 'yen': return { title: up ? 'The yen is weakening' : 'The yen is jumping', detail: up ? 'A weak yen keeps cheap yen borrowing flowing into stocks.' : 'Investors who borrowed cheap yen to buy stocks may have to sell to pay it back.', stat: { label: 'Yen per dollar', value: money(i.price), change: signedPct(i.change_day) } };
    case 'yield': return { title: `Bond yields are ${bp(d)}`, detail: up ? 'Higher borrowing costs make stocks, especially tech, look pricier.' : 'Lower borrowing costs make stocks look cheaper by comparison.', stat: { label: '10-year Treasury yield', value: i.price === null ? '—' : `${i.price.toFixed(2)}%`, change: i.change_day === null ? '—' : `${i.change_day > 0 ? '+' : '−'}${Math.abs(Math.round(i.change_day))} bp` } };
    case 'credit': return { title: up ? 'Lenders are relaxed' : 'Lenders are getting nervous', detail: `Junk bonds are ${pct(d, 2)}. ${up ? 'Easy credit supports company spending.' : 'When risky debt sells off, stocks often follow.'}`, stat: { label: 'High-yield bond fund (HYG)', value: money(i.price, '$'), change: signedPct(i.change_day) } };
    case 'dollar': return { title: `The dollar is ${pct(d, 2)}`, detail: up ? 'A stronger dollar shrinks US companies\' overseas sales.' : 'A weaker dollar boosts US companies\' overseas sales.', stat: { label: 'Dollar index', value: money(i.price), change: signedPct(i.change_day) } };
    case 'europe': return { title: `European stocks closed ${pct(d)}`, detail: 'Europe trades first, and the US often follows its lead.', stat: { label: 'Euro Stoxx 50', value: money(i.price), change: signedPct(i.change_day) } };
    case 'asia': return { title: `Japanese stocks are ${pct(d)}`, detail: 'Asia sets the overnight mood before Europe and the US open.', stat: { label: 'Nikkei 225', value: money(i.price), change: signedPct(i.change_day) } };
    case 'copper': return { title: `Copper is ${pct(d)}`, detail: up ? 'Copper demand rises when factories and builders are busy.' : 'Falling copper hints at slowing global demand.', stat: { label: 'Copper, per pound', value: money(i.price, '$'), change: signedPct(i.change_day) } };
    default: return { title: `Bitcoin is ${pct(d)}`, detail: up ? 'Crypto rallies usually mean investors want more risk.' : 'Crypto selloffs usually mean investors want less risk.', stat: { label: 'Bitcoin', value: money(i.price, '$'), change: signedPct(i.change_day) } };
  }
}

const channelWords: Record<string, string> = { energy: 'oil and energy supply', rates: 'interest rates and the Fed', trade: 'trade and tariffs', growth: 'the economy',
  credit: 'banks and credit', geopolitics: 'conflict and geopolitics', earnings: 'company earnings' };

export function explain(p: Pulse) {
  const drivers: Driver[] = [];
  const symbol = p.symbol;
  for (const i of p.components.market?.inputs ?? []) {
    if (i.status !== 'live' || Math.abs(i.points) < 0.4) continue;
    drivers.push({ kind: 'price', effect: i.points < 0 ? 'lower' : 'higher', points: i.points, ...priceStory(i, symbol) });
  }
  const news = p.components.news;
  if (news.status === 'available' && 'channels' in news && news.channels) {
    for (const c of news.channels) {
      const top = c.top.find(t => Math.sign(t.weight) === Math.sign(c.points)) ?? c.top[0];
      if (!top || Math.abs(c.points) < 0.4) continue;
      drivers.push({ kind: 'news', effect: c.points < 0 ? 'lower' : 'higher', points: c.points, title: top.title, channel: c.channel,
        detail: `Read as ${c.points < 0 ? 'bad' : 'good'} for ${names[symbol]} through ${channelWords[c.channel]}.`, story_id: top.id, url: top.url, source: top.source, at: top.published_at, more: c.stories - 1 });
    }
  } else if (news.status === 'available') {
    for (const f of p.factors) for (const e of f.evidence) {
      if (Math.abs(f.points) < 0.4) continue;
      drivers.push({ kind: 'news', effect: f.points < 0 ? 'lower' : 'higher', points: f.points, title: e.title, detail: `${e.reason}.`, story_id: e.story_id, url: e.url, source: e.source, at: e.published_at });
    }
  }
  for (const r of p.components.calendar?.released ?? []) {
    if (Math.abs(r.points) < 0.4) continue;
    drivers.push({ kind: 'data', effect: r.points < 0 ? 'lower' : 'higher', points: r.points, title: `${r.title} came in ${r.surprise! > 0 ? 'above' : 'below'} forecast`,
      detail: /cpi|pce|ppi|earnings/i.test(r.title) ? (r.points < 0 ? 'Hotter inflation makes Fed rate cuts less likely.' : 'Cooler inflation leaves room for Fed rate cuts.') : r.points < 0 ? 'A weaker reading than expected.' : 'A stronger reading than expected.',
      stat: { label: r.title, value: r.actual ?? '—', change: `Expected ${r.forecast ?? '—'}` }, at: r.at });
  }
  for (const r of p.components.earnings?.released ?? []) {
    if (Math.abs(r.points) < 0.3 || r.surprise === null) continue;
    const beat = r.surprise >= 0, pctText = `${Math.abs(r.surprise * 100).toFixed(1)}%`;
    drivers.push({ kind: 'data', effect: r.points < 0 ? 'lower' : 'higher', points: r.points,
      title: `${r.name} ${beat ? 'beat' : 'missed'} earnings estimates by ${pctText}`,
      detail: r.points < 0 ? (beat ? 'A smaller beat than companies usually deliver.' : `A miss from a company this size weighs on ${names[symbol]}.`) : `A bigger beat than usual lifts ${names[symbol]}.`,
      stat: { label: `${r.name} EPS`, value: r.actual === null ? '—' : r.actual.toFixed(2), change: `Expected ${r.estimate === null ? '—' : r.estimate.toFixed(2)}` }, at: r.at });
  }
  drivers.sort((a, b) => Math.abs(b.points) - Math.abs(a.points));

  const lean = p.score === null ? null : p.score - 50;
  const open = p.horizon === 'next open';
  const when = open ? 'open' : 'rest of the day';
  const call = lean === null ? { headline: 'Not enough to go on', tone: 'neutral' as const, strength: 0 }
    : Math.abs(lean) < 3 ? { headline: 'No clear direction', tone: 'neutral' as const, strength: 0 }
    : { headline: Math.abs(lean) >= 8 ? `Expect a ${lean < 0 ? 'lower' : 'higher'} ${open ? 'open' : 'session'}` : `Leaning ${lean < 0 ? 'lower' : 'higher'} at the ${open ? 'open' : 'close'}`,
      tone: lean < 0 ? 'negative' as const : 'positive' as const, strength: Math.abs(lean) >= 15 ? 3 : Math.abs(lean) >= 8 ? 2 : 1 };
  const against = drivers.filter(d => lean !== null && Math.sign(d.points) === Math.sign(lean));
  const lead = against[0];
  const phrase = (d: Driver) => d.kind === 'news' ? `headlines about ${channelWords[d.channel ?? 'growth'] ?? 'the economy'}` : d.title.charAt(0).toLowerCase() + d.title.slice(1);
  const summary = lean === null ? 'Markets are closed and there is no fresh news to read.'
    : !lead || call.strength === 0 ? `Nothing is pushing ${names[symbol]} hard in either direction right now.`
    : `${phrase(lead).replace(/^./, c => c.toUpperCase())}${against[1] ? `, plus ${phrase(against[1])},` : ''} ${against[1] ? 'point' : 'points'} to ${lean < 0 ? 'weaker' : 'stronger'} ${names[symbol]} at the ${when}.`;
  const coming = [...comingData(p.components.calendar?.upcoming ?? []), ...(p.components.earnings?.upcoming ?? []).map(e => ({
    title: `${e.name} earnings`, at: e.at, timing: session(e.at),
    detail: `${e.estimate === null ? '' : `Expected EPS ${e.estimate.toFixed(2)}. `}${e.weight >= 1 ? `Big enough to move ${names[symbol]} on its own.` : `Can sway ${names[symbol]}.`}` }))]
    .sort((a, b) => a.at.localeCompare(b.at)).slice(0, 8);
  return { call, summary, drivers: drivers.slice(0, 8), coming_up: coming };
}

// Yahoo stamps reports with placeholder times, so only the side of the session is reliable.
function session(at: string) {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date(at));
  const minutes = Number(parts.find(x => x.type === 'hour')?.value) % 24 * 60 + Number(parts.find(x => x.type === 'minute')?.value);
  return minutes < 570 ? 'before the open' : minutes >= 960 ? 'after the close' : undefined;
}

// Releases at the same minute (CPI m/m, y/y, core) are one event to a reader.
function comingData(events: { title: string; at: string; forecast: string | null; high: boolean }[]) {
  const groups = new Map<string, typeof events>();
  for (const e of events) groups.set(e.at, [...(groups.get(e.at) ?? []), e]);
  return [...groups.entries()].map(([at, list]) => {
    const families = [...new Set(list.map(e => e.title.replace(/^Core /, '').replace(/ [mqy]\/[mqy]$/, '').trim()))];
    const headline = list.find(e => e.forecast && e.high && !/^Core /.test(e.title)) ?? list.find(e => e.forecast);
    const high = list.some(e => e.high);
    return { title: families.join(', '), at,
      detail: `${headline?.forecast ? `${headline.title} forecast ${headline.forecast}. ` : ''}${high ? 'A surprise here can outweigh everything above.' : 'Usually a smaller mover.'}` };
  });
}
