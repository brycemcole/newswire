type DB = D1Database;

const questionTtl = 30 * 86400000;
const maxOpenQuestions = 100;
const maxStoredFindings = 1000;
const maxStoredAttempts = 1000;
const maxReportBytes = 256 * 1024;
const maxCount = 10000;
const channels = new Set(['energy', 'rates', 'trade', 'growth', 'credit', 'geopolitics', 'earnings']);

function iso(value: string | number | Date): string {
  const ms = value instanceof Date ? value.getTime() : typeof value === 'number' ? value : Date.parse(value);
  if (!Number.isFinite(ms)) throw new Error('now must be a valid timestamp');
  return new Date(ms).toISOString();
}

export function decodeEntities(value: string): string {
  return value.replace(/&(amp|quot|apos|#39|lt|gt|nbsp);/g, (_, name: string) => ({ amp: '&', quot: '"', apos: "'", '#39': "'", lt: '<', gt: '>', nbsp: ' ' })[name] ?? ' ');
}

function cleanText(value: unknown, max: number): string {
  return typeof value === 'string' ? decodeEntities(value.replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim().slice(0, max) : '';
}

async function hash(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

function safeUrl(value: unknown): string | null {
  try {
    const original = typeof value === 'string' ? value.trim() : '';
    const url = new URL(original);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || original.length > 2000) return null;
    return original;
  } catch { return null; }
}

function safeSource(value: unknown): string {
  const href = safeUrl(value);
  if (!href) return '';
  const url = new URL(href);
  return `${url.protocol}//${url.host}${url.pathname}`.slice(0, 500);
}

function boundedDate(value: unknown, now: string): string | null {
  if (typeof value !== 'string' || value.length > 40) return null;
  const parsed = Date.parse(value), max = Date.parse(now);
  return Number.isFinite(parsed) && parsed <= max ? new Date(parsed).toISOString() : null;
}

function boundedCount(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? Math.min(maxCount, Math.max(0, Math.floor(n))) : 0;
}

function headlineTerms(title: string): string {
  const stop = new Set(['a', 'an', 'and', 'as', 'at', 'after', 'amid', 'by', 'for', 'from', 'in', 'into', 'of', 'on', 'over', 'says', 'said', 'the', 'to', 'with']);
  return [...new Set(title.toLowerCase().match(/[a-z0-9][a-z0-9.'-]*/g) ?? [])]
    .filter(word => !stop.has(word)).slice(0, 9).join(' ');
}

function questionIds(story: Record<string, unknown>): string[] {
  const ids = new Set<string>();
  if (typeof story.question_id === 'string' && story.question_id) ids.add(story.question_id.slice(0, 160));
  if (Array.isArray(story.question_ids)) for (const value of story.question_ids) if (typeof value === 'string' && value) ids.add(value);
  if (Array.isArray(story.provenance)) for (const value of story.provenance) {
    if (typeof value === 'string') {
      const match = /^question:(.{1,160})$/.exec(value);
      if (match) ids.add(match[1]);
    } else if (value && typeof value === 'object') {
      const source = value as Record<string, unknown>;
      const id = cleanText(source.question_id ?? source.questionId ?? (source.kind === 'question' ? source.id : undefined), 160);
      if (id) ids.add(id);
    }
  }
  return [...ids].slice(0, 10);
}

function compactFailures(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 30).map(entry => {
    if (typeof entry === 'string') return cleanText(entry, 240);
    const item = entry && typeof entry === 'object' ? entry as Record<string, unknown> : {};
    const source = safeSource(item.url);
    const error = cleanText(item.error, 240);
    return [source, error].filter(Boolean).join(': ').slice(0, 600);
  }).filter(Boolean);
}

export async function recordDiscovery(db: DB, report: unknown, now: string | number | Date = Date.now()) {
  const recordedAt = iso(now);
  const data = report && typeof report === 'object' ? report as Record<string, unknown> : {};
  const health = ['healthy', 'degraded', 'unhealthy'].includes(String(data.health)) ? String(data.health) : 'unknown';
  const failures = compactFailures(data.failures);
  const rawQuestions = Array.isArray(data.research_questions) ? data.research_questions.slice(0, maxStoredAttempts) : [];
  const rawStories = Array.isArray(data.stories) ? data.stories.slice(0, maxStoredFindings) : [];
  const digestStories = rawStories.flatMap(raw => {
    if (!raw || typeof raw !== 'object') return [];
    const story = raw as Record<string, unknown>, url = safeUrl(story.url), title = cleanText(story.title, 300);
    if (!url || !title) return [];
    return [{ id: cleanText(story.id, 180), url, title, content_hash: cleanText(story.body_hash ?? story.content_hash, 128),
      published_at: boundedDate(story.published_at, recordedAt), observed_at: boundedDate(story.observed_at, recordedAt), provenance: questionIds(story) }];
  });
  const digestQuestions = rawQuestions.flatMap(raw => {
    if (!raw || typeof raw !== 'object') return [];
    const question = raw as Record<string, unknown>;
    return [{ id: cleanText(question.id, 160), last_status: cleanText(question.last_status, 30),
      last_attempt_at: boundedDate(question.last_attempt_at, recordedAt), attempts: boundedCount(question.attempts) }];
  });
  const reportDigest = JSON.stringify({
    started_at: boundedDate(data.started_at, recordedAt), finished_at: boundedDate(data.finished_at, recordedAt), health,
    processed: boundedCount(data.processed), findings: boundedCount(data.findings), unique_findings: boundedCount(data.unique_findings),
    questions_attempted: boundedCount(data.questions_attempted), queued: boundedCount(data.queued), failures,
    stories: digestStories, research_questions: digestQuestions,
  }).slice(0, maxReportBytes);
  const reportHash = await hash(reportDigest);
  const runStatus = data.status === 'running' ? 'running' : data.dry_run ? 'dry_run' : 'complete';
  const number = (key: string) => boundedCount(data[key]);
  const questions = rawQuestions;
  const parentQuestionIds = [...new Set(questions.flatMap(raw => raw && typeof raw === 'object' ? [cleanText((raw as Record<string, unknown>).id, 160)].filter(Boolean) : []))].slice(0, maxStoredAttempts);
  const stories = rawStories;
  for (const raw of stories) if (raw && typeof raw === 'object') for (const id of questionIds(raw as Record<string, unknown>)) parentQuestionIds.push(id);
  const uniqueParentQuestionIds = [...new Set(parentQuestionIds)].slice(0, maxStoredAttempts);
  await db.prepare(`INSERT INTO research_discovery_runs
    (id, started_at, finished_at, recorded_at, health, status, processed, findings, unique_findings, questions_attempted, queued, parent_question_ids_json, failures_json, report_hash)
    VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET started_at=excluded.started_at, finished_at=excluded.finished_at, recorded_at=excluded.recorded_at,
      health=excluded.health, status=excluded.status, processed=excluded.processed, findings=excluded.findings,
      unique_findings=excluded.unique_findings, questions_attempted=excluded.questions_attempted, queued=excluded.queued,
      parent_question_ids_json=excluded.parent_question_ids_json, failures_json=excluded.failures_json, report_hash=excluded.report_hash`)
    .bind(boundedDate(data.started_at, recordedAt), boundedDate(data.finished_at, recordedAt), recordedAt, health, runStatus,
      number('processed'), number('findings'), number('unique_findings'), number('questions_attempted'), number('queued'),
      JSON.stringify(uniqueParentQuestionIds), JSON.stringify(failures), reportHash).run();

  for (const raw of questions) {
    if (!raw || typeof raw !== 'object') continue;
    const question = raw as Record<string, unknown>, id = cleanText(question.id, 160);
    if (!id) continue;
    const status = ['searched', 'failed', 'robots-blocked', 'queued'].includes(String(question.last_status)) ? String(question.last_status) : 'unknown';
    const attemptedAt = boundedDate(question.last_attempt_at, recordedAt) ?? recordedAt;
    const attempts = boundedCount(question.attempts);
    const role = ['confirm', 'contradict', 'explore'].includes(String(question.search_role)) ? String(question.search_role) : null;
    if (status !== 'unknown' || attempts > 0) {
      await db.prepare(`INSERT INTO research_discovery_attempts (question_id, attempted_at, status, attempts, search_role)
        VALUES (?, ?, ?, ?, ?) ON CONFLICT(question_id, attempted_at) DO UPDATE SET status=excluded.status, attempts=excluded.attempts, search_role=excluded.search_role`)
        .bind(id, attemptedAt, status, attempts, role).run();
    }
  }

  let acceptedFindings = 0;
  for (const raw of stories) {
    if (!raw || typeof raw !== 'object') continue;
    const story = raw as Record<string, unknown>, url = safeUrl(story.url), title = cleanText(story.title, 300);
    if (!url || !title) continue;
    if (story.published_at !== null && story.published_at !== undefined && !boundedDate(story.published_at, recordedAt)) continue;
    if (story.observed_at !== null && story.observed_at !== undefined && !boundedDate(story.observed_at, recordedAt)) continue;
    acceptedFindings += 1;
    const id = cleanText(story.id, 180) || await hash(url);
    const bodyHash = cleanText(story.body_hash ?? story.content_hash, 128) || null;
    const firstAt = boundedDate(story.observed_at, recordedAt) ?? recordedAt;
    await db.prepare(`INSERT INTO research_discovery_findings (id, original_url, title, body_hash, first_discovered_at, last_seen_at)
      VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,
      body_hash=COALESCE(excluded.body_hash, research_discovery_findings.body_hash), last_seen_at=excluded.last_seen_at`)
      .bind(id, url, title, bodyHash, firstAt, recordedAt).run();
    for (const questionId of questionIds(story)) {
      await db.prepare(`INSERT INTO research_discovery_finding_questions (finding_id, question_id, provenance) VALUES (?, ?, ?)
        ON CONFLICT(finding_id, question_id) DO UPDATE SET provenance=excluded.provenance`)
        .bind(id, questionId, cleanText(story.search_role, 32) || 'crawler-report').run();
    }
  }

  await db.prepare(`DELETE FROM research_discovery_findings WHERE id NOT IN
    (SELECT id FROM research_discovery_findings ORDER BY last_seen_at DESC LIMIT ?)`)
    .bind(maxStoredFindings).run();
  await db.prepare(`DELETE FROM research_discovery_attempts WHERE rowid NOT IN
    (SELECT rowid FROM research_discovery_attempts ORDER BY attempted_at DESC LIMIT ?)`)
    .bind(maxStoredAttempts).run();
  return { recorded_at: recordedAt, health, status: runStatus, report_sha256: reportHash,
    findings_received: acceptedFindings, questions_received: questions.length };
}

export async function getDiscovery(db: DB) {
  const [run, questions, findings, attempts] = await Promise.all([
    db.prepare('SELECT * FROM research_discovery_runs WHERE id = 1').first<Record<string, unknown>>(),
    db.prepare("SELECT id, query, reason, status, created_at, event_id FROM research_questions WHERE status IN ('open','queued') ORDER BY created_at DESC LIMIT 100").all<Record<string, unknown>>(),
    db.prepare(`SELECT f.id, f.original_url, f.title, f.body_hash, f.first_discovered_at, f.last_seen_at,
      GROUP_CONCAT(fq.question_id) AS question_ids FROM research_discovery_findings f
      LEFT JOIN research_discovery_finding_questions fq ON fq.finding_id=f.id
      GROUP BY f.id ORDER BY f.last_seen_at DESC LIMIT 30`).all<Record<string, unknown>>(),
    db.prepare('SELECT question_id, attempted_at, status, attempts, search_role FROM research_discovery_attempts ORDER BY attempted_at DESC LIMIT 50').all<Record<string, unknown>>(),
  ]);
  return { status: run ? { ...run, failures: JSON.parse(String(run.failures_json ?? '[]')),
    parent_question_ids: JSON.parse(String(run.parent_question_ids_json ?? '[]')) } : null,
    questions: questions.results, findings: findings.results.map(row => ({ ...row, question_ids: row.question_ids ? String(row.question_ids).split(',') : [] })),
    attempts: attempts.results };
}

export async function discoverQuestions(db: DB, pulseSnapshot: unknown, now: string | number | Date = Date.now()) {
  const at = iso(now), cutoff = iso(Date.parse(at) - questionTtl);
  await db.prepare("UPDATE research_questions SET status='dismissed' WHERE status IN ('open','queued') AND created_at < ?").bind(cutoff).run();
  const snapshot = pulseSnapshot && typeof pulseSnapshot === 'object' ? pulseSnapshot as Record<string, any> : {};
  const tops: Array<{ id: string; channel: string; title: string }> = [];
  for (const channel of Array.isArray(snapshot.pulse?.components?.news?.channels) ? snapshot.pulse.components.news.channels : []) {
    if (!channel || !channels.has(String(channel.channel)) || !Array.isArray(channel.top)) continue;
    for (const item of channel.top.slice(0, 2)) {
      const id = cleanText(item?.id, 160), title = cleanText(item?.title, 220);
      if (id && title) tops.push({ id, channel: String(channel.channel), title });
    }
  }
  const candidates = tops.slice(0, 8).flatMap(event => ([
    { role: 'confirm' as const, reason: `Pending independent confirmation of the ${event.channel} report; search results do not establish truth.` },
    { role: 'contradict' as const, reason: `Pending search for contradictions to the ${event.channel} report; search results do not establish truth.` },
  ]));
  const created: Array<{ id: string; query: string; reason: string; status: string; created_at: string; event_id: string }> = [];
  for (let index = 0; index < candidates.length; index++) {
    const event = tops[Math.floor(index / 2)], candidate = candidates[index];
    const id = `rd_${(await hash(`${event.id}|${candidate.role}`)).slice(0, 32)}`;
    const terms = headlineTerms(event.title);
    if (!terms) continue;
    const query = candidate.role === 'confirm' ? `${terms} (official OR statement)` : `${terms} (denied OR corrected OR restored)`;
    await db.prepare(`INSERT INTO research_questions (id, query, reason, status, created_at, event_id)
      VALUES (?, ?, ?, 'open', ?, ?) ON CONFLICT(id) DO NOTHING`).bind(id, query, candidate.reason, at, event.id).run();
    created.push({ id, query, reason: candidate.reason, status: 'open', created_at: at, event_id: event.id });
  }
  await db.prepare(`UPDATE research_questions SET status='dismissed' WHERE status IN ('open','queued') AND id NOT IN
    (SELECT id FROM research_questions WHERE status IN ('open','queued') ORDER BY created_at DESC LIMIT ?)`)
    .bind(maxOpenQuestions).run();
  for (const question of created) {
    const saved = await db.prepare('SELECT query, reason, status, created_at, event_id FROM research_questions WHERE id = ?')
      .bind(question.id).first<Record<string, string>>();
    if (saved) Object.assign(question, saved);
  }
  return { generated: created.length, questions: created };
}
