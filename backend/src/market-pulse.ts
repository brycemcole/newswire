export interface PulseStory {
  id: string; title: string; summary: string; source: string; url: string;
  published_at: string; received_at: string; retracted_at?: string | null;
  tags: string[]; tickers: string[];
}

type Factor = 'energy' | 'trade' | 'rates' | 'growth' | 'credit';

export interface MarketInput {
  id: string; label: string; symbol: string; unit: 'pct' | 'ratio';
  price: number | null; price_at: string | null; change_day: number | null; change_hour: number | null; status: 'live' | 'stale' | 'unavailable';
  members?: { symbol: string; name: string; change: number; weight?: number }[];
}

// Deterministic price inputs. A move of one "typical" 24-hour size gives about three quarters of the input's points;
// the 1-hour move uses a third of that size so a sudden spike registers before the day's change catches up.
const instruments = [
  { kind: 'change', id: 'futures', label: 'S&P 500 futures', symbol: 'ES=F', unit: 'pct', typical: 0.6, points: 16, direction: 1, up: 1, down: 1, stale: 3, baseline: 'cash_close', reason: 'Overnight futures are the best single read on the next open and already price in recent headlines',
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.6, DAL: 1.1 } },
  { kind: 'change', id: 'nasdaq', label: 'Nasdaq 100 futures', symbol: 'NQ=F', unit: 'pct', typical: 0.9, points: 6, direction: 1, up: 1, down: 1, stale: 3, baseline: 'cash_close', reason: 'Tech-heavy futures confirm or contradict the S&P move',
    exposure: { SPY: 1, QQQ: 1.3, XLE: 0.4, DAL: 0.8 } },
  { kind: 'change', id: 'smallcaps', label: 'Russell 2000 futures', symbol: 'RTY=F', unit: 'pct', typical: 1, points: 4, direction: 1, up: 1, down: 1, stale: 3, baseline: 'cash_close', reason: 'Small caps show how broad the overnight move is',
    exposure: { SPY: 0.9, QQQ: 0.7, XLE: 1, DAL: 1.2 } },
  { kind: 'change', id: 'oil', label: 'WTI crude', symbol: 'CL=F', unit: 'pct', typical: 2.5, points: 8, direction: -1, up: 1, down: 1, stale: 3, reason: 'Rising crude raises costs; falling crude eases them',
    exposure: { SPY: 1, QQQ: 0.8, XLE: -1.5, DAL: 1.8 } },
  { kind: 'change', id: 'vix', label: 'VIX', symbol: '^VIX', unit: 'pct', typical: 8, points: 8, direction: -1, up: 1, down: 0.7, stale: 3, reason: 'Rising implied volatility reflects demand for protection',
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.8, DAL: 1.2 } },
  { kind: 'change', id: 'yen', label: 'USD/JPY', symbol: 'JPY=X', unit: 'pct', typical: 0.7, points: 6, direction: 1, up: 0, down: 1, stale: 3, reason: 'A fast yen rally signals carry-trade unwinding and risk reduction',
    exposure: { SPY: 1, QQQ: 1.2, XLE: 0.6, DAL: 0.8 } },
  { kind: 'change', id: 'yield', label: '10-year Treasury futures', symbol: 'ZN=F', unit: 'pct', typical: 0.35, points: 6, direction: 1, up: 0.7, down: 1, stale: 3, reason: 'Rising Treasury prices mean falling yields, which ease pressure on valuations; falling prices do the opposite',
    exposure: { SPY: 1, QQQ: 1.4, XLE: 0.3, DAL: 0.8 } },
  { kind: 'change', id: 'credit', label: 'High-yield bonds (HYG)', symbol: 'HYG', unit: 'pct', typical: 0.4, points: 6, direction: 1, up: 0.6, down: 1, stale: 3, reason: 'Falling junk-bond prices signal credit stress',
    exposure: { SPY: 1, QQQ: 1, XLE: 0.9, DAL: 1.2 } },
  { kind: 'change', id: 'dollar', label: 'US dollar index', symbol: 'DX-Y.NYB', unit: 'pct', typical: 0.5, points: 4, direction: -1, up: 1, down: 0.7, stale: 3, reason: 'A sharply stronger dollar tightens global financial conditions and hurts overseas earnings',
    exposure: { SPY: 1, QQQ: 1, XLE: 0.8, DAL: 0.5 } },
  { kind: 'change', id: 'europe', label: 'Euro Stoxx 50', symbol: '^STOXX50E', unit: 'pct', typical: 1, points: 4, direction: 1, up: 1, down: 1, stale: 18, reason: "Europe's session leads the US open",
    exposure: { SPY: 1, QQQ: 0.9, XLE: 0.8, DAL: 1 } },
  { kind: 'change', id: 'asia', label: 'Nikkei 225', symbol: '^N225', unit: 'pct', typical: 1.3, points: 3, direction: 1, up: 1, down: 1, stale: 18, reason: "Asia's session sets the overnight tone",
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.6, DAL: 0.8 } },
  { kind: 'change', id: 'china', label: 'Hang Seng', symbol: '^HSI', unit: 'pct', typical: 1.3, points: 3, direction: 1, up: 1, down: 1, stale: 18, reason: "Hong Kong trades through Asia's day and reflects China and global risk appetite",
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.8, DAL: 0.7 } },
  { kind: 'change', id: 'germany', label: 'DAX', symbol: '^GDAXI', unit: 'pct', typical: 1, points: 3, direction: 1, up: 1, down: 1, stale: 18, reason: 'Germany is the most cyclical large European market and leads the US open',
    exposure: { SPY: 1, QQQ: 0.9, XLE: 0.8, DAL: 1 } },
  { kind: 'change', id: 'gold', label: 'Gold', symbol: 'GC=F', unit: 'pct', typical: 1, points: 3, direction: -1, up: 0.7, down: 0.5, stale: 3, reason: 'A sharp rush into gold signals demand for safety',
    exposure: { SPY: 1, QQQ: 0.9, XLE: 0.4, DAL: 0.8 } },
  { kind: 'change', id: 'copper', label: 'Copper', symbol: 'HG=F', unit: 'pct', typical: 1.5, points: 3, direction: 1, up: 1, down: 1, stale: 3, reason: 'Copper tracks expectations for global industrial demand',
    exposure: { SPY: 1, QQQ: 0.8, XLE: 1.2, DAL: 0.8 } },
  { kind: 'change', id: 'bitcoin', label: 'Bitcoin', symbol: 'BTC-USD', unit: 'pct', typical: 3, points: 3, direction: 1, up: 1, down: 1, stale: 3, reason: 'Trades around the clock, so it carries risk appetite through weekends',
    exposure: { SPY: 1, QQQ: 1.3, XLE: 0.5, DAL: 0.8 } },
  { kind: 'change', id: 'front_yield', label: '2-year Treasury futures', symbol: 'ZT=F', unit: 'pct', typical: 0.1, points: 4, direction: 1, up: 0.7, down: 1, stale: 3, baseline: 'cash_close', reason: 'The 2-year tracks Fed expectations, which the 10-year alone can hide',
    exposure: { SPY: 1, QQQ: 1.3, XLE: 0.3, DAL: 0.8 } },
  { kind: 'change', id: 'real_yield', label: 'TIPS (TIP)', symbol: 'TIP', unit: 'pct', typical: 0.3, points: 3, direction: 1, up: 0.7, down: 1, stale: 18, baseline: 'cash_close', reason: 'Falling TIPS prices mean rising real yields, which pressure valuations',
    exposure: { SPY: 1, QQQ: 1.4, XLE: 0.3, DAL: 0.7 } },
  { kind: 'relative', id: 'breadth', label: 'Equal-weight vs cap-weight (RSP vs SPY)', symbol: 'RSP', denominator: 'SPY', unit: 'pct', typical: 0.35, points: 3, direction: 1, stale: 18, reason: 'Equal-weight leading cap-weight means the move is broad rather than a handful of megacaps',
    exposure: { SPY: 1, QQQ: 0.5, XLE: 0.6, DAL: 0.8 } },
  { kind: 'relative', id: 'semis', label: 'Semiconductors vs S&P 500 (SMH vs SPY)', symbol: 'SMH', denominator: 'SPY', unit: 'pct', typical: 0.9, points: 3, direction: 1, stale: 18, reason: 'Chip leadership drives the index through its largest weights',
    exposure: { SPY: 1, QQQ: 1.4, XLE: 0.2, DAL: 0.4 } },
  { kind: 'ratio', id: 'vix_short', label: 'VIX9D vs VIX', symbol: '^VIX9D', denominator: '^VIX', unit: 'ratio', stale: 72, neutral: 0.97, scale: 0.08, points: 3, reason: 'Nine-day implied volatility above the 30-day means near-term event fear',
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.8, DAL: 1.2 } },
  { kind: 'ratio', id: 'vix_term', label: 'VIX term structure', symbol: '^VIX', denominator: '^VIX3M', unit: 'ratio', stale: 72, reason: 'A short-term VIX above the 3-month VIX (backwardation) means fear is concentrated now; a calm curve supports stocks',
    exposure: { SPY: 1, QQQ: 1.1, XLE: 0.8, DAL: 1.2 } },
  { kind: 'drawdown', id: 'drawdown', label: 'S&P 500 ETF, 3 sessions', symbol: 'SPY', unit: 'pct', sessions: 3, stale: 96, reason: 'Sharp multi-day selloffs tend to see partial rebounds, so a deep drop adds a little support',
    exposure: { SPY: 1, QQQ: 1, XLE: 0.6, DAL: 0.8 } },
  { kind: 'basket', id: 'premarket', label: 'Bellwether stocks, pre-market', symbol: 'basket', unit: 'pct', direction: 1, points: 6, typical: 1, stale: 0.5, reason: 'Pre-market trades in the largest companies give the first read on the open, before futures settle',
    exposure: { SPY: 1, QQQ: 1, XLE: 1, DAL: 1 } },
] as const;
export interface Impact {
  id: string; title: string; source: string; url: string; published_at: string; received_at: string;
  direction: number; channel: string; size: 'major' | 'moderate' | 'minor'; confidence: number; classified_at: string;
}

export const impactChannels = ['energy', 'rates', 'trade', 'growth', 'credit', 'geopolitics', 'earnings'] as const;
const channelExposure: Record<string, Record<string, number>> = {
  energy: { SPY: 1, QQQ: 0.8, XLE: -1.2, DAL: 1.6 }, rates: { SPY: 1, QQQ: 1.3, XLE: 0.5, DAL: 0.8 },
  trade: { SPY: 1, QQQ: 1.2, XLE: 0.5, DAL: 0.7 }, growth: { SPY: 1, QQQ: 1, XLE: 1, DAL: 1.2 },
  credit: { SPY: 1, QQQ: 1, XLE: 0.9, DAL: 1.2 }, geopolitics: { SPY: 1, QQQ: 1, XLE: 0.3, DAL: 1.3 },
  earnings: { SPY: 1, QQQ: 1.2, XLE: 0.6, DAL: 0.8 },
};
const sizeWeight = { major: 1, moderate: 0.5, minor: 0.2 } as const;

// Repeated titles share the earliest evidence clock and contribute once per channel.
export function scoreImpacts(impacts: Impact[] | undefined, now: number, symbol: string) {
  if (!impacts) return null;
  const available = impacts.filter(i => Number.isFinite(Date.parse(i.classified_at)) && Date.parse(i.classified_at) <= now
    && Date.parse(i.received_at) <= now && Date.parse(i.published_at) <= now);
  const groups = new Map<string, Impact>();
  for (const item of [...available].sort((a, b) => Date.parse(a.received_at) - Date.parse(b.received_at) || a.id.localeCompare(b.id))) {
    const key = `${item.channel}|${item.direction}|${item.title.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim()}`;
    if (!groups.has(key)) groups.set(key, item);
  }
  const evidenceAt = (item: Impact) => {
    const published = Date.parse(item.published_at), received = Date.parse(item.received_at);
    // Midnight UTC is a common date-only RSS placeholder; preserve exact publication ages otherwise.
    return new Date(published).toISOString().endsWith('T00:00:00.000Z') && received - published < 24 * hour ? received : Math.min(published, received);
  };
  const live = [...groups.values()].filter(i => evidenceAt(i) > now - 48 * hour && i.direction !== 0)
    .map(i => {
      const age = (now - evidenceAt(i)) / hour;
      // Energy shocks hurt most stocks but help energy producers.
      const exposure = channelExposure[i.channel]?.[symbol] ?? 1;
      return { ...i, weight: round(i.direction * Math.sign(exposure) * sizeWeight[i.size] * i.confidence * 2 ** (-age / 12)), exposure: Math.abs(exposure) };
    });
  const channels = impactChannels.map(channel => {
    const items = live.filter(i => i.channel === channel);
    const exposure = channelExposure[channel][symbol] ?? 1;
    const sum = items.reduce((s, i) => s + i.weight, 0);
    return { channel, points: round(Math.tanh(sum / 1.5) * 6 * Math.abs(exposure)), stories: items.length,
      top: [...items].sort((a, b) => Math.abs(b.weight) - Math.abs(a.weight)).slice(0, 3) };
  }).filter(c => c.stories);
  return { points: round(clamp(channels.reduce((s, c) => s + c.points, 0), 25)), classified: available.filter(i => Date.parse(i.received_at) > now - 48 * hour).length, channels };
}

export interface CalendarEvent { title: string; at: string; forecast: string | null; actual: string | null; surprise: number | null; threshold: number | null; actual_available_at?: string | null; impact?: string }

// Above-forecast inflation or joblessness is a headwind; above-forecast activity a modest tailwind.
const releaseDirection = (title: string) => /cpi|pce|ppi|earnings|unemployment|claims/i.test(title) ? -1 : /employment change|retail|gdp|jolts|pmi|ism/i.test(title) ? 0.6 : 0;

export function scoreCalendar(events: CalendarEvent[] | undefined, now: number, symbol: string, requireVintage = false) {
  if (!events) return null;
  const exposure = { SPY: 1, QQQ: 1.2, XLE: 0.6, DAL: 0.9 }[symbol] ?? 1;
  const vintageAvailable = (e: CalendarEvent) => !requireVintage || (typeof e.actual_available_at === 'string'
    && Number.isFinite(Date.parse(e.actual_available_at)) && Date.parse(e.actual_available_at) <= now);
  // Medium-impact releases (Fed speakers, auctions, inventories) are listed as coming up but never scored.
  const high = (e: CalendarEvent) => e.impact === undefined || e.impact === 'High';
  const released = events.filter(e => high(e) && Date.parse(e.at) <= now && Date.parse(e.at) > now - 24 * hour && e.surprise !== null && e.threshold && vintageAvailable(e))
    .map(e => ({ ...e, points: round(releaseDirection(e.title) * Math.tanh(e.surprise! / e.threshold!) * 5 * exposure) }));
  const upcoming = events.filter(e => Date.parse(e.at) > now && Date.parse(e.at) <= now + 18 * hour).map(({ title, at, forecast, impact }) => ({ title, at, forecast, high: impact === undefined || impact === 'High' }));
  const withheld = requireVintage && events.some(e => Date.parse(e.at) <= now && Date.parse(e.at) > now - 24 * hour && e.surprise !== null && e.threshold && !vintageAvailable(e));
  return { points: round(clamp(released.reduce((sum, e) => sum + e.points, 0), 10)), released, upcoming,
    ...(requireVintage ? { actuals_status: withheld ? 'withheld_no_archived_vintage' : 'archived_vintage_only' } : {}) };
}

// Companies whose results move the index or the profile on their own. Weights are per profile: SPY, QQQ, XLE, DAL.
export const bellwethers: Record<string, { name: string; weight: [number, number, number, number] }> = {
  NVDA: { name: 'Nvidia', weight: [1.5, 2, 0.3, 0.3] }, MSFT: { name: 'Microsoft', weight: [1.3, 1.6, 0.2, 0.2] },
  AAPL: { name: 'Apple', weight: [1.3, 1.6, 0.2, 0.2] }, AMZN: { name: 'Amazon', weight: [1.2, 1.5, 0.2, 0.3] },
  GOOGL: { name: 'Alphabet', weight: [1.2, 1.5, 0.2, 0.2] }, META: { name: 'Meta', weight: [1, 1.3, 0.2, 0.2] },
  AVGO: { name: 'Broadcom', weight: [0.8, 1.1, 0.1, 0.1] }, TSLA: { name: 'Tesla', weight: [0.7, 1, 0.1, 0.1] },
  TSM: { name: 'TSMC', weight: [0.9, 1.3, 0.1, 0.1] }, ASML: { name: 'ASML', weight: [0.8, 1.2, 0.1, 0.1] },
  NFLX: { name: 'Netflix', weight: [0.5, 0.8, 0, 0.1] }, JPM: { name: 'JPMorgan', weight: [0.9, 0.4, 0.3, 0.4] },
  BAC: { name: 'Bank of America', weight: [0.5, 0.2, 0.2, 0.3] }, GS: { name: 'Goldman Sachs', weight: [0.5, 0.2, 0.2, 0.2] },
  WMT: { name: 'Walmart', weight: [0.6, 0.4, 0.1, 0.3] }, LLY: { name: 'Eli Lilly', weight: [0.5, 0.2, 0, 0] },
  UNH: { name: 'UnitedHealth', weight: [0.4, 0.1, 0, 0] }, XOM: { name: 'Exxon Mobil', weight: [0.4, 0.1, 1.6, 0] },
  CVX: { name: 'Chevron', weight: [0.3, 0.1, 1.2, 0] }, DAL: { name: 'Delta', weight: [0.2, 0.1, 0.1, 1.6] },
  UAL: { name: 'United Airlines', weight: [0.1, 0.1, 0.1, 1.2] },
};
// Column order of each bellwether's weight tuple.
export const profileOrder = ['SPY', 'QQQ', 'XLE', 'DAL'];
export const basketSymbols = Object.keys(bellwethers).filter(symbol => Math.max(...bellwethers[symbol].weight) >= 0.8);

export interface EarningsEvent { symbol: string; at: string; estimate: number | null; actual: number | null; surprise: number | null }
export interface EarningsFeed { events: EarningsEvent[]; loaded: number; requested: number; error?: string }

// About three in four companies beat EPS estimates, so a small beat is the expected result and only the excess counts.
const typicalBeat = 0.04, surpriseScale = 0.08;

export function scoreEarnings(events: EarningsEvent[] | undefined, now: number, symbol: string) {
  if (!events) return null;
  const column = pulseModel.symbols.indexOf(symbol as typeof pulseModel.symbols[number]);
  const weightOf = (s: string) => bellwethers[s]?.weight[column] ?? 0;
  const released = events.filter(e => Date.parse(e.at) <= now && Date.parse(e.at) > now - 24 * hour && e.surprise !== null && weightOf(e.symbol) > 0)
    .map(e => ({ ...e, name: bellwethers[e.symbol].name, weight: weightOf(e.symbol), points: round(Math.tanh((e.surprise! - typicalBeat) / surpriseScale) * 1.5 * weightOf(e.symbol)) }));
  const upcoming = events.filter(e => Date.parse(e.at) > now && Date.parse(e.at) <= now + 36 * hour && weightOf(e.symbol) >= 0.5)
    .map(e => ({ symbol: e.symbol, name: bellwethers[e.symbol].name, at: e.at, estimate: e.estimate, weight: weightOf(e.symbol) }));
  return { points: round(clamp(released.reduce((sum, e) => sum + e.points, 0), 6)), released, upcoming,
    pending: upcoming.some(e => e.weight >= 1 && Date.parse(e.at) <= now + 18 * hour) };
}

// Backtested Jul–Oct 2026: the 7 a.m. score tracked the close-to-open gap (SPY r≈0.44) but not the open-to-close move (r≈0.12).
export function pulseHorizon(now: number) {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', weekday: 'short', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date(now));
  const get = (type: string) => parts.find(p => p.type === type)?.value ?? '';
  const minutes = Number(get('hour')) % 24 * 60 + Number(get('minute'));
  const open = !['Sat', 'Sun'].includes(get('weekday')) && minutes >= 570 && minutes < 960;
  return open ? { horizon: 'rest of session', predictive: false } : { horizon: 'next open', predictive: true };
}

export const marketInstruments = instruments.map(spec => ({ id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, stale: spec.stale, kind: spec.kind,
  baseline: 'baseline' in spec ? spec.baseline : undefined,
  neutral: 'neutral' in spec ? spec.neutral : undefined,
  scale: 'scale' in spec ? spec.scale : undefined,
  denominator: 'denominator' in spec ? spec.denominator : undefined,
  sessions: 'sessions' in spec ? spec.sessions : undefined }));

// Ratio levels score against a fixed neutral point; drawdowns are contrarian, so a deep drop adds support.
function instrumentPoints(spec: (typeof instruments)[number], input: MarketInput | undefined, exposure: number): number {
  if (spec.kind === 'basket') return 0;
  if (spec.kind === 'ratio') return input?.status === 'live' && input.price !== null
    ? -('points' in spec ? spec.points : 4) * Math.tanh((input.price - ('neutral' in spec ? spec.neutral : 0.92)) / ('scale' in spec ? spec.scale : 0.08)) * exposure : 0;
  if (spec.kind === 'relative') return input?.status === 'live' && input.change_day !== null ? spec.direction * spec.points * Math.tanh(input.change_day / spec.typical) * exposure : 0;
  if (spec.kind === 'drawdown') return input?.status === 'live' && input.change_day !== null ? -3 * Math.tanh(input.change_day / 3) * exposure : 0;
  const usable = input?.status === 'live' && input.change_day !== null;
  const signal = usable ? 0.7 * Math.tanh(input!.change_day! / spec.typical) + 0.3 * Math.tanh((input!.change_hour ?? 0) / (spec.typical / 3)) : 0;
  const weight = (spec.up + spec.down) / 2;
  return spec.direction * weight * signal * spec.points * exposure;
}

// A live quote without the value its type needs (a missing baseline) cannot describe a move, so it is not counted as live.
// Zero is a real value and stays live.
function hasSignal(spec: (typeof instruments)[number], input: MarketInput | undefined): boolean {
  if (spec.kind === 'ratio') return input?.price !== null && input?.price !== undefined;
  return input?.change_day !== null && input?.change_day !== undefined;
}

function withSignal(status: MarketInput['status'], usable: boolean): MarketInput['status'] {
  return status === 'live' && !usable ? 'unavailable' : status;
}

export function scoreMarket(inputs: MarketInput[] | undefined, symbol: string) {
  if (!inputs) return null;
  const scored = instruments.map(spec => {
    const input = inputs.find(i => i.id === spec.id);
    const exposure = spec.exposure[symbol as keyof typeof spec.exposure];
    const base = input ?? { id: spec.id, label: spec.label, symbol: spec.symbol, unit: spec.unit, price: null, price_at: null, change_day: null, change_hour: null, status: 'unavailable' as const };
    if (spec.kind === 'basket') {
      const column = profileOrder.indexOf(symbol);
      const members = input?.status === 'live' ? (input.members ?? []).map(m => ({ ...m, weight: bellwethers[m.symbol]?.weight[column] ?? 0 })).filter(m => m.weight > 0) : [];
      const total = members.reduce((sum, m) => sum + m.weight, 0);
      const change = total > 0 ? round(members.reduce((sum, m) => sum + m.weight * m.change, 0) / total) : null;
      return { ...base, status: withSignal(base.status, change !== null), exposure, reason: spec.reason, change_day: change, members, points: change === null ? 0 : round(spec.direction * spec.points * Math.tanh(change / spec.typical) * exposure) };
    }
    return { ...base, status: withSignal(base.status, hasSignal(spec, input)), exposure, reason: spec.reason, points: round(instrumentPoints(spec, input, exposure)) };
  });
  const live = scored.filter(i => i.status === 'live').length;
  return { status: live >= 3 ? 'available' as const : 'unavailable' as const, live_inputs: live,
    points: live >= 3 ? round(clamp(scored.reduce((sum, i) => sum + i.points, 0), 40)) : 0, inputs: scored };
}
interface Rule {
  id: string; factor: Factor; direction: number; reason: string;
  subject: RegExp; trigger: RegExp;
}

export const pulseModel = {
  version: 'market-pulse-v2.2', windowHours: 96, halfLifeHours: 36,
  staleAfterHours: 24, factorPoints: { energy: 12, trade: 10, rates: 10, growth: 8, credit: 10 },
  symbols: ['SPY', 'QQQ', 'XLE', 'DAL'],
  calibration: 'Uncalibrated research index; not a probability or expected return.',
} as const;

const exposures: Record<string, Record<Factor, number>> = {
  SPY: { energy: 1, trade: 1, rates: 1, growth: 1, credit: 1 },
  QQQ: { energy: 0.8, trade: 1, rates: 1.2, growth: 1, credit: 1 },
  XLE: { energy: -1, trade: 0.4, rates: 0.4, growth: 1, credit: 0.7 },
  DAL: { energy: 1.5, trade: 0.5, rates: 0.5, growth: 1.2, credit: 1 },
};

const rules: Rule[] = [
  { id: 'supply-risk', factor: 'energy', direction: -1, reason: 'Potential energy supply disruption and input-cost pressure',
    subject: /\b(oil|crude|energy|tanker|tankers|hormuz|saudi|riyadh|aramco|houthi|houthis|refiner\w*|pipeline)\b/i,
    trigger: /\b(attack\w*|strike[sd]?|missiles?|explosions?|blockade|disrupt\w*|shut\w*|halts?|halted|outage|block\w*|supply (?:loss|risk|threat))\b/i },
  { id: 'supply-relief', factor: 'energy', direction: 1, reason: 'Potential energy supply relief',
    subject: /\b(oil|crude|energy|hormuz|saudi|riyadh|iran|russia|ukraine|opec|pipeline)\b/i,
    trigger: /\b(ceasefire (?:agreed|signed|takes effect)|agree\w* (?:to |on )?(?:a )?ceasefire|resumes? (?:oil |crude )?(?:exports|production|shipments)|restores? (?:oil |crude )?(?:supply|production)|releases? (?:oil |strategic )?reserves)\b/i },
  { id: 'trade-tightening', factor: 'trade', direction: -1, reason: 'Trade restrictions raise costs or reduce market access',
    subject: /\b(us|u\.s\.|united states|trump|china|chinese|beijing)\b/i,
    trigger: /\b(imposes?|raises?|hikes?|announces?) (?:new |higher |additional |\d+%? )?(?:tariffs|export restrictions|export controls)|\b(?:bans?|restricts?) (?:chip |semiconductor )?exports\b/i },
  { id: 'trade-relief', factor: 'trade', direction: 1, reason: 'Reduced trade restrictions could support margins and demand',
    subject: /\b(us|u\.s\.|united states|trump|china|chinese|beijing)\b/i,
    trigger: /\b(cuts?|reduces?|lifts?|suspends?|removes?) (?:trade |import |new )?(?:tariffs|export restrictions|export controls)\b/i },
  { id: 'policy-tightening', factor: 'rates', direction: -1, reason: 'Tighter US monetary policy or an upside inflation surprise',
    subject: /\b(fed|federal reserve|fomc|us inflation|u\.s\. inflation|cpi|pce)\b/i,
    trigger: /\b(raises?|hikes?) (?:interest |policy )?rates\b|\b(?:inflation|cpi|pce)\b.{0,55}\b(hotter|higher|above) than (?:expected|forecast)\b/i },
  { id: 'policy-relief', factor: 'rates', direction: 1, reason: 'Easier US monetary policy or a downside inflation surprise',
    subject: /\b(fed|federal reserve|fomc|us inflation|u\.s\. inflation|cpi|pce)\b/i,
    trigger: /\b(cuts?|lowers?) (?:interest |policy )?rates\b|\b(?:inflation|cpi|pce)\b.{0,55}\b(cooler|lower|below) than (?:expected|forecast)\b/i },
  { id: 'growth-weakness', factor: 'growth', direction: -1, reason: 'Reported US activity weakness could pressure earnings',
    subject: /\b(us|u\.s\.|united states|american)\b/i,
    trigger: /\b(?:gdp|retail sales|payrolls|employment|manufacturing)\b.{0,45}\b(contracts?|shrinks?|plunges?|falls? unexpectedly|below expectations)\b/i },
  { id: 'growth-strength', factor: 'growth', direction: 1, reason: 'Reported US activity strength could support earnings',
    subject: /\b(us|u\.s\.|united states|american)\b/i,
    trigger: /\b(?:gdp|retail sales|manufacturing)\b.{0,45}\b(beats? expectations|above expectations|expands? faster)\b/i },
  { id: 'credit-stress', factor: 'credit', direction: -1, reason: 'Systemic funding stress could tighten financial conditions',
    subject: /\b(us|u\.s\.|united states|american|global)\b/i,
    trigger: /\b(banking crisis|bank runs?|credit crunch|funding crisis|liquidity crisis)\b/i },
];

const hour = 3600000;
const clean = (text: string) => text.replace(/<[^>]*>/g, ' ').replace(/&(?:nbsp|amp|quot|#\d+);/g, ' ').replace(/\s+/g, ' ').trim();
const round = (n: number) => Math.round(n * 100) / 100;
const clamp = (n: number, bound: number) => Math.max(-bound, Math.min(bound, n));
const headline = (s: PulseStory) => s.tags.some(t => t === 'headlines' || t === 'x');
const subjectKey = (text: string) => /hormuz|iran/i.test(text) ? 'hormuz' : /saudi|riyadh|houthi|aramco/i.test(text) ? 'saudi' : /russia|ukraine/i.test(text) ? 'russia' : /gulf coast|hurricane/i.test(text) ? 'gulf-coast' : 'general';
// Regional editions of one outlet ("Yahoo Finance UK", "Yahoo! Finance Canada") are one source.
const outlet = (source: string) => source.toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').split(/\s+/).filter(word => word && !/^(uk|us|usa|canada|india|australia|singapore|international|edition)$/.test(word)).join(' ');

export function pulseTime(value: string): number {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) throw new Error('as_of must be an ISO timestamp with timezone');
  const date = value.slice(0, 10), parsed = new Date(`${date}T00:00:00Z`);
  if (!Number.isFinite(+parsed) || parsed.toISOString().slice(0, 10) !== date || Number(value.slice(11, 13)) > 23 || Number(value.slice(14, 16)) > 59 || Number(value.slice(17, 19)) > 59) throw new Error('Invalid as_of timestamp');
  return Date.parse(value);
}

export function calculatePulse(stories: PulseStory[], asOf: string, symbol = 'SPY', truncated = false, extras: { market?: MarketInput[]; calendar?: CalendarEvent[]; earnings?: EarningsFeed; impacts?: Impact[]; calendarRequiresVintage?: boolean; impactInputsTruncated?: boolean } = {}) {
  const now = pulseTime(asOf);
  symbol = symbol.toUpperCase();
  if (!Object.hasOwn(exposures, symbol)) throw new Error(`Supported symbols: ${pulseModel.symbols.join(', ')}`);
  const start = now - pulseModel.windowHours * hour;
  const eligible = stories.filter(s => {
    const published = Date.parse(s.published_at), received = Date.parse(s.received_at);
    return Number.isFinite(published) && Number.isFinite(received) && published <= now && received <= now && published >= start
      && (!s.retracted_at || Date.parse(s.retracted_at) > now);
  }).sort((a, b) => Date.parse(a.received_at) - Date.parse(b.received_at) || a.id.localeCompare(b.id));
  const news = eligible.filter(headline);
  const latest = news.reduce((last, s) => Math.max(last, Math.min(Date.parse(s.published_at), Date.parse(s.received_at))), -Infinity);
  const age = Number.isFinite(latest) ? (now - latest) / hour : null;
  const evidence: { story_id: string; title: string; source: string; url: string; published_at: string; received_at: string; rule: string; factor: Factor; direction: number; confidence: number; strength: number; reason: string; cluster: string; independent_sources: number; x: boolean }[] = [];
  const anchors = new Map<string, number>();
  for (const s of news) {
    const title = clean(s.title);
    // A title must supply the event; summaries can qualify it but cannot introduce a second event.
    if (/\?|\b(if|could|would|may|might|should|rumou?rs?|denies?|denied|no|not|didn't|doesn't|won't|last year|years? ago)\b/i.test(title)) continue;
    for (const rule of rules) {
      if (!rule.subject.test(title) || !rule.trigger.test(title)) continue;
      if (rule.factor === 'energy' && !/\b(hormuz|saudi|riyadh|aramco|houthi|houthis|iran|opec|russia|russian|ukraine|ukrainian|gulf coast|global (?:oil|crude)|world (?:oil|crude))\b/i.test(title)) continue;
      const cluster = `${rule.id}:${subjectKey(title)}`;
      const published = Date.parse(s.published_at);
      const anchor = Math.min(anchors.get(cluster) ?? published, published);
      anchors.set(cluster, anchor);
      const confidence = s.tags.includes('x') ? 0.4 : /\b(claims?|reportedly|unconfirmed|reports of)\b/i.test(title) ? 0.55 : 0.8;
      evidence.push({ story_id: s.id, title, source: s.source, url: s.url, published_at: s.published_at, received_at: s.received_at,
        rule: rule.id, factor: rule.factor, direction: rule.direction, confidence, strength: 0, reason: rule.reason, cluster, independent_sources: 1, x: s.tags.includes('x') });
    }
  }
  // Independent publishers can confirm an unconfirmed report up to the confirmed level; copies never add strength beyond that.
  for (const e of evidence) {
    const outlets = new Set(evidence.filter(other => other.cluster === e.cluster && other.direction === e.direction && !other.x).map(other => outlet(other.source)));
    e.independent_sources = Math.max(1, outlets.size);
    if (!e.x && e.confidence < 0.8) e.confidence = Math.min(0.8, e.confidence + 0.1 * (e.independent_sources - 1));
  }
  for (const e of evidence) e.strength = e.confidence * 2 ** (-(now - anchors.get(e.cluster)!) / (pulseModel.halfLifeHours * hour));
  const factors = (Object.keys(pulseModel.factorPoints) as Factor[]).map(factor => {
    const relevant = evidence.filter(e => e.factor === factor);
    const best = (direction: number) => relevant.filter(e => e.direction === direction).sort((a, b) => b.strength - a.strength || a.received_at.localeCompare(b.received_at) || a.story_id.localeCompare(b.story_id))[0];
    const positive = best(1), negative = best(-1);
    const strength = (positive?.strength ?? 0) - (negative?.strength ?? 0);
    return { factor, points: round(strength * pulseModel.factorPoints[factor] * exposures[symbol][factor]),
      exposure: exposures[symbol][factor], conflicting: Boolean(positive && negative),
      evidence: [negative, positive].filter((e): e is NonNullable<typeof e> => Boolean(e)).map(e => ({ ...e, strength: round(e.strength) })) };
  });
  // Jev's per-headline reads replace the keyword rules whenever they are available.
  const read = scoreImpacts(extras.impacts, now, symbol);
  const useRead = Boolean(read && read.classified);
  const market = scoreMarket(extras.market, symbol);
  const marketLive = market?.status === 'available';
  // Headlines from the last few days are already in live futures, so counting both double-counts old news against the market's verdict.
  const futuresLive = Boolean(market?.inputs.some(i => i.id === 'futures' && i.status === 'live'));
  const newsPoints = (useRead ? read!.points : factors.reduce((sum, f) => sum + f.points, 0)) * (futuresLive ? 0.5 : 1);
  const newsSignal = useRead ? read!.channels.some(c => Math.abs(c.points) >= 0.1) : evidence.length > 0;
  const newsStatus = truncated ? 'incomplete' : !news.length && !useRead ? 'no_coverage' : !useRead && age! > pulseModel.staleAfterHours ? 'stale' : !newsSignal ? 'no_signal' : 'available';
  const calendar = scoreCalendar(extras.calendar, now, symbol, extras.calendarRequiresVintage);
  const earnings = scoreEarnings(extras.earnings?.events, now, symbol);
  const calendarPoints = (calendar?.points ?? 0) + (earnings?.points ?? 0);
  const released = Boolean(calendar?.released.length || earnings?.released.length);
  // News points count only when coverage is current; live prices alone can carry the score.
  const counted = (newsStatus === 'available' ? newsPoints : 0) + (marketLive ? market!.points : 0) + calendarPoints;
  const raw = newsSignal || marketLive || released ? round(50 + clamp((newsSignal ? newsPoints : 0) + (marketLive ? market!.points : 0) + calendarPoints, 50)) : null;
  const status = truncated ? 'incomplete' : marketLive || released ? 'available' : newsStatus;
  const score = status === 'available' ? round(50 + clamp(counted, 50)) : null;
  return {
    model: pulseModel.version, as_of: new Date(now).toISOString(), symbol, ...pulseHorizon(now),
    score, research_score: raw, status,
    outlook: score === null ? 'unavailable' : score < 40 ? 'headwinds' : score > 60 ? 'tailwinds' : 'balanced',
    // A scheduled high-impact release or bellwether report still ahead can overwhelm everything the score knows now.
    confidence: status !== 'available' || calendar?.upcoming.some(e => e.high) || earnings?.pending || (factors.filter(f => f.evidence.length).length < 2 && !(marketLive && newsStatus === 'available')) ? 'low' : 'medium',
    components: { news: { status: newsStatus, points: newsStatus === 'available' ? round(newsPoints) : 0, method: useRead ? 'jev' : 'rules', ...(useRead ? { classified: read!.classified, channels: read!.channels } : {}) }, ...(market ? { market } : {}), ...(calendar ? { calendar } : {}), ...(earnings ? { earnings: { points: earnings.points, released: earnings.released, upcoming: earnings.upcoming, coverage: { loaded: extras.earnings!.loaded, requested: extras.earnings!.requested, ...(extras.earnings!.error ? { error: extras.earnings!.error } : {}) } } } : {}) },
    coverage: { window_start: new Date(start).toISOString(), eligible_stories: eligible.length, headline_stories: news.length,
      matched_stories: new Set(evidence.map(e => e.story_id)).size, event_groups: anchors.size, impact_inputs_truncated: extras.impactInputsTruncated ?? false,
      latest_headline_at: Number.isFinite(latest) ? new Date(latest).toISOString() : null, headline_age_hours: age === null ? null : round(age), truncated },
    factors, limitations: [pulseModel.calibration, 'Conservative headline rules cover only explicit macro events; unmatched stories are unclassified, not neutral.',
      market ? 'Price inputs are delayed Yahoo Finance quotes scored by fixed rules; they describe current conditions, not a forecast of returns.' : 'No price inputs, forecasts of returns, company earnings model, or automatic attribution of market moves.',
      'Historical calculations use current model rules with point-in-time news; they were not predictions saved at the time.',
      ...(earnings ? ['Bellwether earnings count by EPS surprise beyond a typical beat; guidance and revenue reach the score only through headlines. Requests for a past time omit earnings because estimates are not archived point in time.'] : []),
      ...(calendar?.actuals_status === 'withheld_no_archived_vintage' ? ['Historical calendar actuals are withheld because no point-in-time vintage is archived.'] : []),
      ...(status !== 'available' ? ['A tradable outlook is withheld when coverage is stale, incomplete, absent, or contains no recognized signal.'] : [])],
  };
}

const liveInputCache = new WeakMap<D1Database, Map<number, Awaited<ReturnType<typeof readPulseInputs>>>>();

async function loadPulseInputs(db: D1Database, asOf: string, historyHours: number) {
  const now = pulseTime(asOf), wall = Date.now();
  if (now > wall) throw new Error('as_of cannot be in the future');
  if (wall - now > 5000) return readPulseInputs(db, asOf, historyHours);
  let cache = liveInputCache.get(db);
  if (!cache) { cache = new Map(); liveInputCache.set(db, cache); }
  const saved = cache.get(historyHours);
  if (saved && now >= saved.now && wall - saved.now < 120000) return saved;
  const inputs = await readPulseInputs(db, asOf, historyHours);
  if (!inputs.impacts) return inputs;
  if (cache.size >= 4) cache.delete(cache.keys().next().value!);
  cache.set(historyHours, inputs);
  return inputs;
}

async function readPulseInputs(db: D1Database, asOf: string, historyHours: number) {
  const now = pulseTime(asOf);
  if (now > Date.now()) throw new Error('as_of cannot be in the future');
  const iso = new Date(now).toISOString(), start = new Date(now - (pulseModel.windowHours + historyHours) * hour).toISOString();
  const impactResult = await db.prepare('SELECT * FROM pulse_impacts WHERE received_at >= ? AND received_at <= ? ORDER BY received_at LIMIT 5001')
    .bind(new Date(now - (historyHours + 48) * hour).toISOString(), iso).all<Impact>().then(r => r.results).catch(() => undefined);
  const impactInputsTruncated = (impactResult?.length ?? 0) > 5000;
  const impactRows = impactResult?.slice(0, 5000);
  const { results } = await db.prepare(`SELECT id, title, '' AS summary, source, url, published_at, received_at, retracted_at, tags, tickers FROM stories
    WHERE published_at >= ? AND published_at <= ? AND received_at <= ? AND (retracted_at IS NULL OR retracted_at > ?)
    ORDER BY published_at DESC, id DESC LIMIT 8001`).bind(start, iso, iso, iso).all<Record<string, unknown>>();
  const stories = results.slice(0, 8000).map(row => ({ ...row, tags: JSON.parse(row.tags as string), tickers: JSON.parse(row.tickers as string) })) as PulseStory[];
  return { now, iso, stories, truncated: results.length > 8000, impacts: impactRows, impactInputsTruncated };
}

export async function loadPulseSnapshot(db: D1Database, asOf: string, symbol = 'SPY', marketInputs?: MarketInput[], calendar?: CalendarEvent[], earnings?: EarningsFeed) {
  const { iso, stories, truncated, impacts, impactInputsTruncated } = await loadPulseInputs(db, asOf, 0);
  const pulse = calculatePulse(stories, iso, symbol, truncated || impactInputsTruncated, { market: marketInputs, calendar, earnings, impacts, impactInputsTruncated });
  return { created_at: new Date().toISOString(), as_of: iso, pulse: { ...pulse, ...explain(pulse) },
    inputs: { stories, impacts: impacts ?? [], market: marketInputs ?? null, calendar: calendar ?? null, ...(earnings ? { earnings } : {}) }, model: pulseModel };
}

export async function loadPulse(db: D1Database, asOf: string, symbol = 'SPY', marketAt?: (t: number) => MarketInput[] | undefined, historyHours = 0, calendar?: CalendarEvent[], earnings?: EarningsFeed) {
  const { now, iso, stories, truncated, impacts, impactInputsTruncated } = await loadPulseInputs(db, asOf, historyHours);
  const calendarRequiresVintage = historyHours > 0 || now < Date.now() - 60000;
  const outcomes = await learningOutcomes(db, symbol, iso);
  const current = adaptPulse(calculatePulse(stories, iso, symbol, truncated || impactInputsTruncated, { market: marketAt?.(now), calendar, earnings, impacts, calendarRequiresVintage, impactInputsTruncated }), outcomes);
  if (!historyHours) return { ...current, ...explain(current) };
  const step = 30 * 60000, history = [];
  for (let t = Math.ceil((now - historyHours * hour) / step) * step; t < now; t += step) {
    const p = adaptPulse(calculatePulse(stories, new Date(t).toISOString(), symbol, truncated || impactInputsTruncated, { market: marketAt?.(t), calendar, earnings, impacts, calendarRequiresVintage: true, impactInputsTruncated }), outcomes);
    history.push({ as_of: p.as_of, score: p.score, news_points: p.components.news.points, market_points: p.components.market?.points ?? 0,
      calendar_points: p.components.calendar?.points ?? 0, earnings_points: p.components.earnings?.points ?? 0, calendar_actuals_status: p.components.calendar?.actuals_status });
  }
  history.push({ as_of: current.as_of, score: current.score, news_points: current.components.news.points, market_points: current.components.market?.points ?? 0, calendar_points: current.components.calendar?.points ?? 0, earnings_points: current.components.earnings?.points ?? 0 });
  return { ...current, ...explain(current), history };
}

import { explain } from './pulse-text';
import { adaptPulse, learningOutcomes } from './adaptive-forecast';
