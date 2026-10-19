function latestReopen(now) {
  const format = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' });
  const parts = Object.fromEntries(format.formatToParts(new Date(now)).map(p => [p.type, p.value]));
  let day = new Date(Date.UTC(+parts.year, +parts.month - 1, +parts.day));
  if (+parts.hour < 18) day = new Date(+day - 86400000);
  if ([5, 6].includes(day.getUTCDay())) return null;
  const guess = +day + 18 * 3600000;
  const hour = +Object.fromEntries(format.formatToParts(new Date(guess)).map(p => [p.type, p.value])).hour;
  return guess + (18 - hour) * 3600000;
}

export function sessionAlertEvents(alerts, schedule, quotes, state, now = Date.now()) {
  const events = [];
  for (const alert of alerts) {
    if (alert.kind === 'event') {
      const at = Date.parse(alert.at), key = `session:${alert.id}:event`;
      if (now >= at && now - at < 120000 && !state[key]) events.push({ key, title: alert.title, body: 'Your scheduled market reminder.' });
      continue;
    }
    if (alert.kind === 'reopen') {
      const at = latestReopen(now), quote = quotes['ES=F'];
      const key = `session:${alert.id}:${at}`;
      if (at !== null && now >= at && now - at < 15 * 60000 && quote?.price > 0 && quote.at >= at && quote.at <= now + 60000 && now - quote.at <= 300000 && !state[key]) {
        events.push({ key, title: 'Futures have reopened', body: 'A fresh S&P 500 futures quote is available. Check the overnight market in Newswire.', symbol: 'ES=F' });
      }
      continue;
    }
    if (alert.kind === 'preopen' || alert.kind === 'close') {
      for (const session of schedule?.sessions ?? []) {
        const at = alert.kind === 'preopen' ? Date.parse(session.open) - alert.minutes * 60000 : Date.parse(session.close) + 5 * 60000;
        const key = `session:${alert.id}:${session.date}`;
        if (now >= at && now - at < 120000 && !state[key]) {
          events.push({ key, title: alert.kind === 'preopen' ? `Market opens in ${alert.minutes} minutes` : 'The closing bell',
            body: alert.kind === 'preopen' ? 'Check futures and the latest headlines before the opening bell.' : 'Review today’s market moves and latest headlines in Newswire.' });
        }
      }
      continue;
    }
    if (alert.kind !== 'move') continue;
    const quote = quotes[alert.symbol];
    if (!(quote?.price > 0 && quote.previousClose > 0) || !Number.isFinite(quote.at) || now - quote.at > 300000 || quote.at > now + 60000) continue;
    const change = (quote.price / quote.previousClose - 1) * 100;
    const meets = alert.direction === 'up' ? change + 1e-8 >= alert.threshold : alert.direction === 'down' ? change - 1e-8 <= -alert.threshold : Math.abs(change) + 1e-8 >= alert.threshold;
    const key = `session:${alert.id}:move`;
    const previous = state[key];
    if (!meets) {
      if (previous) previous.armed = true;
    } else if (!previous || (previous.armed && now - Date.parse(previous.at) >= 1800000)) {
      events.push({ key, symbol: alert.symbol, title: `${{ 'ES=F': 'S&P 500', 'NQ=F': 'Nasdaq 100', 'RTY=F': 'Russell 2000' }[alert.symbol]} futures ${change >= 0 ? 'up' : 'down'} ${Math.abs(change).toFixed(2)}%`,
        body: 'Compared with the previous settlement reference. Open Newswire for the quote and latest headlines.' });
    }
  }
  return events;
}
