function roundRobin(entries, preferred, limit) {
  const priority = new Map(preferred.map((publisher, index) => [publisher.toLowerCase(), index]));
  const groups = new Map();
  for (const entry of entries) {
    const name = entry.item.x && entry.item.discovery ? `discovery:${entry.item.discovery}` : `${entry.item.x ? 'x:' : ''}${entry.item.publisher.toLowerCase()}`;
    if (!groups.has(name)) groups.set(name, []);
    groups.get(name).push(entry);
  }
  const ordered = [...groups.values()].sort((a, b) =>
    Number(Boolean(a[0].item.x)) - Number(Boolean(b[0].item.x)) ||
    (priority.get(a[0].item.publisher.toLowerCase()) ?? preferred.length) - (priority.get(b[0].item.publisher.toLowerCase()) ?? preferred.length));
  for (const group of ordered) group.sort((a, b) => b.item.stamp - a.item.stamp);
  const selected = [];
  for (let round = 0; selected.length < limit; round++) {
    let added = false;
    for (const group of ordered) {
      if (group[round]) { selected.push(group[round]); added = true; }
      if (selected.length === limit) break;
    }
    if (!added) break;
  }
  return selected;
}

export function classificationCandidates(entries, preferred = [], limit = 16) {
  const articles = entries.filter(entry => !entry.item.x);
  const posts = entries.filter(entry => entry.item.x);
  const xSlots = Math.min(Math.floor(limit / 4), posts.length);
  const direct = roundRobin(posts.filter(entry => !entry.item.discovery), preferred, Math.ceil(xSlots / 2));
  const discovered = roundRobin(posts.filter(entry => entry.item.discovery), preferred, Math.floor(xSlots / 2));
  const selectedPosts = [...direct, ...discovered];
  const remainingPosts = posts.filter(entry => !selectedPosts.includes(entry));
  selectedPosts.push(...roundRobin(remainingPosts, preferred, xSlots - selectedPosts.length));
  const selected = [...roundRobin(articles, preferred, limit - selectedPosts.length), ...selectedPosts];
  selected.push(...roundRobin(posts.filter(entry => !selectedPosts.includes(entry)), preferred, limit - selected.length));
  return selected;
}
