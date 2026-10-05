const $ = (selector) => document.querySelector(selector);
const state = { token: '', stories: [], cursor: null, category: '', q: '', priority: '', selected: null, generation: 0, busy: false };
const formatTime = (value) => new Date(value).toLocaleTimeString('en-GB', { timeZone: 'UTC', hour: '2-digit', minute: '2-digit' });
const formatDate = (value) => new Date(value).toLocaleDateString('en-GB', { timeZone: 'UTC', day: '2-digit', month: 'short' });
const escape = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function notice(text, error = false) { $('#notice').textContent = text; $('#notice').className = error ? 'error' : ''; }
function status(text, live = false) { $('#status').textContent = text; $('#status-dot').className = live ? 'live' : ''; }
function query(cursor) {
  const params = new URLSearchParams({ limit: '50' });
  for (const key of ['category', 'q', 'priority']) if (state[key]) params.set(key, state[key]);
  if (cursor) params.set('cursor', cursor);
  return params;
}
async function request(cursor) {
  const response = await fetch(`/v1/stories?${query(cursor)}`, { headers: { Authorization: `Bearer ${state.token}` }, cache: 'no-store' });
  if (!response.ok) {
    const payload = await response.json().catch(() => null);
    throw new Error(payload?.error?.message || `Request failed (${response.status}).`);
  }
  return response.json();
}
function render() {
  $('#stories').innerHTML = state.stories.map((s) => `<button class="story ${state.selected === s.id ? 'selected' : ''}" data-id="${escape(s.id)}"><div class="stamp">${formatTime(s.published_at)}<small>${formatDate(s.published_at)}</small><small>${escape(s.source)}</small></div><div><div class="story-title">${escape(s.title)}</div><div class="meta"><span class="category">${escape(s.category)}</span>${s.priority !== 'normal' ? `<span class="${escape(s.priority)}">● ${escape(s.priority.toUpperCase())}</span>` : ''}${s.tickers.map((t) => `<span class="ticker">${escape(t)}</span>`).join('')}<span>${escape(s.agent)}</span></div></div></button>`).join('');
  $('#load-more').hidden = !state.cursor;
  $('#count').textContent = `${state.stories.length} STORIES LOADED`;
  if (!state.stories.length) notice('The wire is quiet. Stories uploaded by your agents will appear here.');
}
function resetInspector() {
  const detail = $('#detail');
  detail.classList.remove('open');
  detail.innerHTML = '<div class="detail-label">STORY INSPECTOR <span>02</span></div><div class="inspector-empty"><div class="crosshair">+</div><h2>Follow the signal.</h2><p>Select a headline to read the report, inspect its source, and see which agent sent it.</p><div class="legend"><span><i class="amber"></i> NORMAL</span><span><i class="red"></i> BREAKING</span></div></div>';
}
async function load(older = false) {
  if (!state.token || (older && state.busy)) return;
  const generation = ++state.generation;
  state.busy = true;
  $('#load-more').disabled = true;
  status('SYNCING');
  notice(state.stories.length ? '' : 'Connecting to the wire…');
  try {
    const data = await request(older ? state.cursor : null);
    if (generation !== state.generation) return;
    state.stories = older ? [...state.stories, ...data.stories.filter((s) => !state.stories.some((existing) => existing.id === s.id))] : data.stories;
    if (!older && state.selected && !state.stories.some((story) => story.id === state.selected)) {
      state.selected = null; resetInspector();
    }
    state.cursor = data.next_cursor;
    $('#new-stories').hidden = true;
    notice(''); render();
    if ($('#detail').classList.contains('open') && state.selected) detail(state.selected);
    status('CONNECTED', true);
    $('#updated').textContent = `UPDATED ${formatTime(Date.now())} UTC`;
  } catch (error) {
    if (generation === state.generation) { status('CONNECTION ERROR'); notice(error.message, true); }
  } finally {
    if (generation === state.generation) { state.busy = false; $('#load-more').disabled = false; }
  }
}
function closeDetail() {
  const id = state.selected;
  state.selected = null; resetInspector(); render();
  document.querySelector(`#stories [data-id="${CSS.escape(id || '')}"]`)?.focus();
}
function detail(id, preserveAction = null) {
  const s = state.stories.find((story) => story.id === id);
  if (!s) return;
  const currentAction = $('#detail').contains(document.activeElement) ? document.activeElement.dataset.inspectorAction : null;
  preserveAction ||= currentAction;
  state.selected = id; render();
  const index = state.stories.findIndex((story) => story.id === id);
  const controls = `<div class="report-controls"><button id="report-prev" data-inspector-action="previous" ${index === 0 ? 'disabled' : ''}>← PREVIOUS</button><span id="report-position">${index + 1} OF ${state.stories.length} LOADED</span><button id="report-next" data-inspector-action="next" ${index === state.stories.length - 1 ? 'disabled' : ''}>NEXT →</button><button id="report-close" class="close-detail" data-inspector-action="close">CLOSE</button></div>`;
  const url = new URL(s.url);
  const sourceLink = ['https:', 'http:'].includes(url.protocol) ? `<a href="${escape(url.href)}" target="_blank" rel="noopener noreferrer">OPEN ORIGINAL SOURCE ↗</a>` : '';
  $('#detail').innerHTML = `<div class="detail-label">STORY INSPECTOR <span>02</span></div>${controls}<article class="report"><span class="eyebrow">${escape(s.category.toUpperCase())} / ${escape(s.priority.toUpperCase())}</span><h2>${escape(s.title)}</h2><p class="summary">${escape(s.summary)}</p><div class="body">${escape(s.body)}</div><dl><dt>SOURCE</dt><dd>${escape(s.source)}</dd><dt>PUBLISHED / UTC</dt><dd>${escape(new Date(s.published_at).toUTCString())}</dd><dt>REPORTING AGENT</dt><dd>${escape(s.agent)}</dd>${s.tags.length ? `<dt>TAGS</dt><dd>${s.tags.map(escape).join(' / ')}</dd>` : ''}</dl>${sourceLink}</article>`;
  $('#detail').classList.add('open');
  $('#detail').scrollTop = 0;
  if (preserveAction) {
    const target = $(`[data-inspector-action="${preserveAction}"]`);
    (target && !target.disabled ? target : $('#report-close')).focus({ preventScroll: true });
  }
}
$('#detail').onclick = (event) => {
  const action = event.target.closest('[data-inspector-action]')?.dataset.inspectorAction;
  if (!action) return;
  const index = state.stories.findIndex((story) => story.id === state.selected);
  if (action === 'close') closeDetail();
  else if (action === 'previous' && index > 0) detail(state.stories[index - 1].id, action);
  else if (action === 'next' && index < state.stories.length - 1) detail(state.stories[index + 1].id, action);
};
$('#stories').onclick = (event) => { const row = event.target.closest('[data-id]'); if (row) detail(row.dataset.id); };
$('#connect').onclick = () => $('#settings').showModal();
$('#cancel').onclick = () => $('#settings').close();
$('#connection-form').onsubmit = (event) => { event.preventDefault(); state.token = $('#token').value.trim(); $('#token').value = ''; $('#settings').close(); $('#connect').textContent = 'CONNECTION'; load(); };
function filterChanged() { state.stories = []; state.cursor = null; state.selected = null; resetInspector(); $('#new-stories').hidden = true; render(); load(); }
$('#categories').onclick = (event) => {
  const button = event.target.closest('[data-category]');
  if (!button) return;
  state.category = button.dataset.category;
  $('#categories .selected').classList.remove('selected'); button.classList.add('selected'); filterChanged();
};
let searchTimer;
$('#search').oninput = () => { clearTimeout(searchTimer); state.generation++; state.busy = false; searchTimer = setTimeout(() => { state.q = $('#search').value.trim(); filterChanged(); }, 250); };
$('#priority').onchange = () => { state.priority = $('#priority').value; filterChanged(); };
$('#refresh').onclick = () => load();
$('#load-more').onclick = () => load(true);
$('#new-stories').onclick = () => { window.scrollTo({ top: 0, behavior: 'instant' }); load(); };
function revealSelection() { document.querySelector(`#stories [data-id="${state.selected}"]`)?.scrollIntoView({ block: 'nearest' }); }
document.addEventListener('keydown', (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement.tagName) || $('#settings').open) return;
  if (event.key === '/') { event.preventDefault(); $('#search').focus(); return; }
  if (event.key === 'Escape') { if ($('#detail').classList.contains('open')) closeDetail(); return; }
  if (!state.stories.length || !['j', 'k', 'Enter', 'o'].includes(event.key)) return;
  const index = state.stories.findIndex((story) => story.id === state.selected);
  if (event.key === 'Enter' || event.key === 'o') {
    if (state.selected && !$('#detail').classList.contains('open')) detail(state.selected);
    return;
  }
  const target = Math.max(0, Math.min(state.stories.length - 1, index < 0 ? (event.key === 'j' ? 0 : state.stories.length - 1) : index + (event.key === 'j' ? 1 : -1)));
  if (target === index) return;
  if ($('#detail').classList.contains('open')) detail(state.stories[target].id); else { state.selected = state.stories[target].id; render(); }
  revealSelection();
});
setInterval(async () => {
  if (!state.token || state.busy || document.hidden) return;
  const generation = state.generation;
  try {
    const data = await request(null);
    if (generation !== state.generation || state.busy) return;
    const newCount = data.stories.filter((s) => !state.stories.some((existing) => existing.id === s.id)).length;
    if (newCount) { $('#new-stories').textContent = `${newCount} NEW ${newCount === 1 ? 'STORY' : 'STORIES'} · SHOW LATEST ↑`; $('#new-stories').hidden = false; }
    status('CONNECTED', true); $('#updated').textContent = `CHECKED ${formatTime(Date.now())} UTC`;
  } catch { status('OFFLINE · RETRYING'); }
}, 30000);
function tick() { $('#clock').textContent = `${new Date().toLocaleTimeString('en-GB', { timeZone: 'UTC' })} UTC`; }
tick(); setInterval(tick, 1000);
notice('Connect your access token to open the private news wire.');
