import { nextSession, sessionFor } from './forecast';

export function marketSchedule(now = Date.now()) {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(now));
  const current = sessionFor(today);
  const next = current && now < current.close ? { date: today, ...current } : nextSession(today);
  const sessions = [];
  let cursor = current ? { date: today, ...current } : nextSession(today);
  for (let i = 0; i < 8; i++) {
    sessions.push({ date: cursor.date, open: new Date(cursor.open).toISOString(), close: new Date(cursor.close).toISOString() });
    cursor = nextSession(cursor.date);
  }
  return { as_of: new Date(now).toISOString(), phase: current && now >= current.open && now < current.close ? 'open' : current && now < current.open ? 'premarket' : 'closed',
    next_open: new Date(next.open > now ? next.open : nextSession(today).open).toISOString(),
    close: current ? new Date(current.close).toISOString() : null, sessions };
}

export function validSessionAlerts(value: unknown): boolean {
  if (!Array.isArray(value) || value.length > 20) return false;
  const ids = new Set();
  return value.every(a => {
    if (!a || typeof a !== 'object' || typeof a.id !== 'string' || !/^[a-zA-Z0-9-]{1,64}$/.test(a.id) || ids.has(a.id)) return false;
    ids.add(a.id);
    if (a.kind === 'preopen') return [5, 15, 30, 60].includes(a.minutes);
    if (a.kind === 'close' || a.kind === 'reopen') return true;
    if (a.kind === 'event') return typeof a.at === 'string' && Number.isFinite(Date.parse(a.at)) && typeof a.title === 'string' && a.title.length > 0 && a.title.length <= 120;
    return a.kind === 'move' && ['ES=F', 'NQ=F', 'RTY=F'].includes(a.symbol) && ['either', 'up', 'down'].includes(a.direction)
      && typeof a.threshold === 'number' && Number.isFinite(a.threshold) && a.threshold >= 0.25 && a.threshold <= 10;
  });
}
