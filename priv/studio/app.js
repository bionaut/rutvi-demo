'use strict';
const $ = id => document.getElementById(id);
const terminal = new Set(['completed', 'needs_review', 'failed', 'cancelled']);
const roles = {research: 'Research', plan: 'Planning', author: 'Writing', review: 'Review'};
const sourceNames = {S1: 'Events and commands', S2: 'Delivery', S3: 'Idempotency', S4: 'Recovery', S5: 'Concurrency', S6: 'External effects'};
let csrf, reference, timer, busy = false, cursor = 0, events = [], artifact, checkpoint, sources = [];
let configuredProviderBadge = 'Connecting…', artifactSignature, selectedTab = 'overview';
let tasks = new Map(), lastStatus;
const node = (tag, text, className) => {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
};
function showError(message) {$('error').textContent = message; $('error').hidden = false;}
function clearError() {$('error').hidden = true;}
async function api(path, method = 'GET', body) {
  const options = {method, credentials: 'same-origin', headers: {}};
  if (method !== 'GET') {
    options.headers = {'content-type': 'application/json', 'x-rutvi-csrf': csrf};
    options.body = JSON.stringify(body || {});
  }
  const response = await fetch('/studio-api/' + path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || data.error || 'Request failed.');
  return data;
}
function setBusy(value) {
  busy = value;
  $('generate').disabled = value || !csrf;
  $('generate').textContent = value ? 'Course in progress…' : 'Generate course ↗';
  $('cancel').hidden = !value;
  for (const input of $('course-form').querySelectorAll('input, select, textarea')) {
    input.disabled = value || (input.id === 'audience' && $('ask-audience').checked);
  }
}
function roleOf(service) {return String(service || '').replace('course.', '');}

// Model text becomes text nodes only. Raw HTML is never interpreted.
function inline(parent, text) {
  const pattern = /(\*\*[^*\n]+\*\*|__[^_\n]+__|`[^`\n]+`|\*[^*\n]+\*|\[[^\]\n]+\]\([^\s)]+\))/g;
  let position = 0;
  for (const match of String(text).matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(position, match.index)));
    const token = match[0];
    if (token.startsWith('**') || token.startsWith('__')) parent.append(node('strong', token.slice(2, -2)));
    else if (token.startsWith('`')) parent.append(node('code', token.slice(1, -1)));
    else if (token.startsWith('*')) parent.append(node('em', token.slice(1, -1)));
    else {
      const link = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      let url;
      try {url = new URL(link[2]);} catch (_) {url = null;}
      if (url && ['https:', 'http:'].includes(url.protocol)) {
        const anchor = node('a', link[1]);
        anchor.href = url.href; anchor.rel = 'noopener noreferrer'; anchor.target = '_blank';
        parent.append(anchor);
      } else parent.append(document.createTextNode(token));
    }
    position = match.index + token.length;
  }
  parent.append(document.createTextNode(text.slice(position)));
  return parent;
}
function markdown(text) {
  const body = node('div', undefined, 'lesson-body');
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  let index = 0;
  const special = line => /^(#{1,6}\s|```|\s*[-*+]\s|\s*\d+[.)]\s|>\s?)/.test(line);
  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) {index++; continue;}
    if (/^```/.test(line)) {
      const block = [];
      index++;
      while (index < lines.length && !/^```/.test(lines[index])) block.push(lines[index++]);
      index++;
      const pre = node('pre'); pre.append(node('code', block.join('\n'))); body.append(pre);
    } else if (/^#{1,6}\s/.test(line)) {
      const heading = line.match(/^(#{1,6})\s+(.*)$/);
      body.append(inline(node(heading[1].length < 3 ? 'h3' : 'h4'), heading[2])); index++;
    } else if (/^\s*[-*+]\s/.test(line) || /^\s*\d+[.)]\s/.test(line)) {
      const ordered = /^\s*\d+[.)]\s/.test(line);
      const marker = ordered ? /^\s*\d+[.)]\s+(.*)$/ : /^\s*[-*+]\s+(.*)$/;
      const list = node(ordered ? 'ol' : 'ul');
      while (index < lines.length && marker.test(lines[index])) list.append(inline(node('li'), lines[index++].match(marker)[1]));
      body.append(list);
    } else if (/^>\s?/.test(line)) {
      const quote = [];
      while (index < lines.length && /^>\s?/.test(lines[index])) quote.push(lines[index++].replace(/^>\s?/, ''));
      body.append(inline(node('blockquote'), quote.join(' ')));
    } else {
      const paragraph = [lines[index++]];
      while (index < lines.length && lines[index].trim() && !special(lines[index])) paragraph.push(lines[index++]);
      body.append(inline(node('p'), paragraph.join(' ')));
    }
  }
  return body;
}
function setTab(name, focus = false) {
  const tab = $('tab-' + name);
  if (!tab || tab.disabled) return;
  selectedTab = name;
  for (const button of $('reader-tabs').querySelectorAll('[role=tab]')) {
    const active = button.dataset.tab === name;
    button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1;
    $('panel-' + button.dataset.tab).hidden = !active;
  }
  if (focus) tab.focus();
}
function citations(list) {
  const el = node('div', undefined, 'citations');
  el.append(node('span', 'Referenced passages'));
  for (const citation of list || []) {
    const button = node('button', citation.source_id + '/' + citation.passage_id, 'citation-link');
    button.type = 'button';
    button.addEventListener('click', () => {
      setTab('sources', true);
      const passage = $('source-' + citation.source_id);
      if (passage) {passage.focus({preventScroll: true}); passage.scrollIntoView({block: 'nearest'});}
    });
    el.append(button);
  }
  return el;
}
function navigationButton(text, target) {
  const button = node('button', text); button.type = 'button';
  button.addEventListener('click', () => setTab(target, true));
  return button;
}
function nextSection(text, target) {
  const next = node('div', undefined, 'reader-next');
  next.append(navigationButton(text + ' →', target)); return next;
}
function plainTitle(text) {return String(text || '').replace(/[*`_]/g, '').replace(/^#+\s*/, '');}
function lessonTitle(lesson, number) {
  const heading = String(lesson.text || '').match(/^#{1,3}\s+(.+)$/m);
  return plainTitle(lesson.title || (heading && heading[1]) || 'Lesson ' + number);
}
function renderSources() {
  const panel = $('panel-sources'); panel.replaceChildren();
  panel.append(node('p', 'SOURCE LIBRARY', 'section-kicker'), node('h3', 'Reference passages', 'content-title'), node('p', 'The six passages supplied with this exercise. Lesson and quiz citations refer to these identifiers.', 'content-intro'));
  for (const source of sources) {
    const section = node('article', undefined, 'source-passage');
    section.id = 'source-' + source.source_id; section.tabIndex = -1;
    const heading = node('header');
    heading.append(node('span', source.source_id + '/' + source.passage_id, 'source-id'), node('h4', sourceNames[source.source_id] || 'Reference passage'));
    section.append(heading, node('p', source.text)); panel.append(section);
  }
}
function renderResult(data) {
  if (!data) return;
  const signature = JSON.stringify(data);
  if (signature === artifactSignature) return;
  artifact = data; artifactSignature = signature;
  $('reader-title').textContent = data.title || 'Your course';
  $('reader-subtitle').textContent = data.audience ? 'For ' + data.audience : 'Your completed course';
  $('download').href = '/studio-api/tasks/' + encodeURIComponent(reference) + '/export';
  $('download').hidden = lastStatus !== 'completed';
  const overview = $('panel-overview'); overview.replaceChildren();
  const meta = node('div', undefined, 'overview-meta');
  for (const [label, value] of [['Lessons', (data.lessons || []).length], ['Questions', (data.questions || []).length], ['Language', 'Czech']]) {
    const item = node('div'); item.append(node('span', label), document.createTextNode(String(value))); meta.append(item);
  }
  overview.append(meta, node('h3', 'What you will learn', 'content-title'));
  const objectives = node('ol', undefined, 'objectives');
  for (const objective of data.objectives || []) {const item = node('li'); item.append(inline(node('div'), objective.text || objective.id)); objectives.append(item);}
  overview.append(objectives, node('h4', 'Course outline', 'section-label'));
  const links = node('div', undefined, 'lesson-links');
  (data.lessons || []).forEach((lesson, index) => {
    const number = index + 1, tab = 'lesson-' + number;
    const button = navigationButton('', tab); button.className = 'lesson-link';
    const copy = node('span', lessonTitle(lesson, number), 'lesson-link-copy');
    const objective = (data.objectives || []).find(item => item.id === lesson.objective_id);
    if (objective) copy.append(node('small', plainTitle(objective.text)));
    button.append(node('span', 'Lesson ' + number, 'lesson-index'), copy, node('span', '↗', 'arrow')); links.append(button);
    const panel = $('panel-' + tab); panel.replaceChildren();
    panel.append(node('p', 'LESSON ' + number + (lesson.revision ? ' · REVISION ' + lesson.revision : ''), 'section-kicker'), node('h3', lessonTitle(lesson, number), 'content-title'));
    if (objective) panel.append(node('p', plainTitle(objective.text), 'content-intro'));
    let text = String(lesson.text || '');
    const firstHeading = text.match(/^#{1,3}\s+(.+)\n?/);
    if (firstHeading && plainTitle(firstHeading[1]) === lessonTitle(lesson, number)) text = text.slice(firstHeading[0].length);
    panel.append(markdown(text), citations(lesson.citations), nextSection(number === 1 ? 'Continue to Lesson 2' : 'Check your understanding', number === 1 ? 'lesson-2' : 'quiz'));
    $('tab-' + tab).disabled = false;
  });
  overview.append(links);
  const revisions = [...new Map(events.filter(event => event.type === 'revision').map(event => [event.revision + ':' + (event.lesson_ids || []).join(','), event])).values()];
  const note = lastStatus === 'completed' ? 'Research, writing, and source review are complete.' : lastStatus === 'needs_review' ? 'The reviewer requested further changes. This is the saved draft.' : 'Saved course content. See Progress for the current review status.';
  overview.append(node('p', note + (revisions.length ? ' ' + revisions.length + ' targeted revision' + (revisions.length === 1 ? '' : 's') + ' recorded.' : ''), 'review-note'));
  const quiz = $('panel-quiz'); quiz.replaceChildren();
  quiz.append(node('p', 'CHECK YOUR UNDERSTANDING', 'section-kicker'), node('h3', 'A short knowledge check', 'content-title'), node('p', 'Consider each question, then expand it to see the answer and explanation.', 'content-intro'));
  for (const question of data.questions || []) {
    const details = node('details', undefined, 'quiz-question');
    const summary = node('summary'); summary.append(node('span', question.id, 'question-index'), inline(node('span'), question.question));
    const answer = node('div', undefined, 'quiz-answer');
    answer.append(inline(node('p'), question.answer), inline(node('p'), question.explanation), citations(question.citations));
    details.append(summary, answer); quiz.append(details);
  }
  $('tab-quiz').disabled = !(data.questions || []).length;
  $('setup-config').open = false;
  $('setup-summary').replaceChildren(document.createTextNode('New course'), node('span', '+'));
  renderSources(); setTab(selectedTab);
}
function eventText(event) {
  const role = roleOf(event.service_id);
  const task = tasks.get(event.task_id);
  if (event.type === 'completed') {
    if (role === 'create') return 'Course ready to read.';
    if (role === 'author') return (task?.input?.lesson_id === 'L2' ? 'Lesson 2' : task?.input?.lesson_id === 'L1' ? 'Lesson 1' : 'Lesson') + ' written.';
    if (role === 'research' && event.parent_id !== reference) return null;
    return (roles[role] || 'Course') + ' completed.';
  }
  if (event.type === 'waiting_for_human') return 'Planner needs your answer.';
  if (event.type === 'resumed') return 'Your answer was saved. Planning continued.';
  if (event.type === 'revision') return 'Reviewer requested changes to ' + (event.lesson_ids || []).map(id => id.replace('L', 'Lesson ')).join(', ') + '.';
  if (event.type === 'needs_review') return 'Draft saved. Further review needed.';
  if (event.type === 'failed' && role === 'create') return 'Course could not be completed.';
  if (event.type === 'cancelled' && role === 'create') return 'Course cancelled.';
  if (event.type === 'model_response' && event.outcome?.status === 'error') return (roles[role] || 'Agent') + ' response needed another attempt.';
  return null;
}
function renderTimeline() {
  const items = [], seen = new Set();
  for (const event of events) {
    const text = eventText(event);
    if (!text) continue;
    const key = event.type === 'revision' ? 'revision:' + event.revision + ':' + (event.lesson_ids || []).join(',') : event.type === 'waiting_for_human' || event.type === 'resumed' ? event.sequence : text;
    if (seen.has(key)) continue;
    seen.add(key); items.push({event, text});
  }
  $('timeline').replaceChildren();
  for (const {event, text} of items.slice(-20).reverse()) {
    const item = node('li'); item.append(node('time', new Date(event.timestamp).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'})), node('span', text)); $('timeline').append(item);
  }
  if (!items.length) $('timeline').append(node('li', reference ? 'Agents are working. Updates appear as stages finish.' : 'No course started yet.', 'muted'));
  $('event-count').textContent = items.length ? String(items.length) : '';
}
function renderStages() {
  for (const item of $('stages').querySelectorAll('li')) {
    const taskEvents = events.filter(event => roleOf(event.service_id) === item.dataset.role);
    const states = new Map();
    for (const event of taskEvents) if (['queued', 'running', 'completed', 'failed', 'cancelled', 'waiting_for_human', 'waiting_for_children'].includes(event.type)) states.set(event.task_id, event.type);
    const values = [...states.values()];
    const state = values.includes('failed') ? 'failed' : values.includes('cancelled') ? 'stopped' : values.includes('waiting_for_human') ? 'paused' : values.length && values.every(value => value === 'completed') ? 'done' : values.length ? 'active' : '';
    item.dataset.state = state;
    item.querySelector('.stage-state').textContent = ({done: 'Complete', paused: 'Your input', failed: 'Failed', stopped: 'Stopped', active: 'Working'})[state] || '—';
  }
}
function renderQuestion(snapshot) {
  if (terminal.has(snapshot.status)) {$('question').hidden = true; checkpoint = null; return;}
  const cp = (snapshot.checkpoints || []).find(item => !item.response);
  if (!cp) {$('question').hidden = true; checkpoint = null; return;}
  if (checkpoint?.checkpoint_id === cp.checkpoint_id) return;
  checkpoint = cp; $('question').hidden = false; $('answer-fields').replaceChildren();
  const properties = cp.resume_schema?.properties || {};
  $('question-title').textContent = properties.audience ? 'Who is this course for?' : properties.style ? 'Which learning style?' : cp.message || 'Follow-up question';
  for (const [key, schema] of Object.entries(properties)) {
    const id = 'answer-' + key;
    const label = node('label', key === 'audience' ? 'Audience' : key === 'style' ? 'Learning style' : key); label.htmlFor = id;
    const input = node(schema.enum ? 'select' : 'input'); input.id = id; input.name = key; input.required = (cp.resume_schema.required || []).includes(key);
    if (schema.enum) for (const value of schema.enum) {const option = node('option', value); option.value = value; input.append(option);}
    else {input.maxLength = 300; input.value = key === 'audience' ? $('audience').value : '';}
    if (key === 'style') input.value = $('style').value;
    $('answer-fields').append(label, input);
  }
}
async function poll() {
  if (!reference) return;
  try {
    const [snapshot, more] = await Promise.all([api('tasks/' + encodeURIComponent(reference)), api('tasks/' + encodeURIComponent(reference) + '/history?after_seq=' + cursor)]);
    lastStatus = snapshot.status;
    tasks = new Map([snapshot, ...(snapshot.children || []), ...(snapshot.waiting_descendants || [])].map(task => [task.task_id, task]));
    for (const event of more) {events.push(event); cursor = Math.max(cursor, event.sequence);}
    renderTimeline(); renderStages(); renderQuestion(snapshot);
    const actualModel = [...events].reverse().find(event => event.type === 'model_response' && event.outcome?.model)?.outcome.model;
    $('provider').textContent = actualModel === 'deterministic' ? 'Demonstration · sample responses' : actualModel ? 'Real AI · ' + actualModel : configuredProviderBadge;
    const labels = {queued: 'Queued', running: 'Agents working', waiting_for_children: 'Agents working', waiting_for_human: 'Your answer needed', completed: 'Course complete', needs_review: 'Review needed', cancelled: 'Cancelled', failed: 'Failed'};
    $('task-status').textContent = checkpoint ? 'Your answer needed' : labels[snapshot.status] || snapshot.status;
    $('progress-note').textContent = checkpoint ? 'Answer the planner to continue.' : snapshot.status === 'completed' ? 'All stages finished. Your course is saved.' : snapshot.status === 'cancelled' ? 'You can generate another course.' : snapshot.status === 'failed' ? 'Your progress and history are saved.' : 'Updates reflect the agents’ recorded work.';
    if (snapshot.result) renderResult(snapshot.result);
    else if (terminal.has(snapshot.status)) {
      const cancelled = snapshot.status === 'cancelled';
      $('reader-title').textContent = cancelled ? 'Course cancelled' : 'Course could not be completed';
      $('reader-subtitle').textContent = 'Your progress and activity history are saved.';
      $('panel-overview').replaceChildren(node('h3', cancelled ? 'Start again when you’re ready.' : 'You can try another course.', 'content-title'), node('p', 'Open the course settings to start again. Your saved activity is available under Progress.', 'content-intro'));
      $('download').hidden = true;
    }
    if (terminal.has(snapshot.status)) {setBusy(false); clearTimeout(timer); if (snapshot.status === 'failed') showError('The course could not be completed. Your progress and history are saved. You can generate another course.');}
    else {setBusy(true); timer = setTimeout(poll, 1000);}
  } catch (error) {setBusy(false); showError(error.message + ' Refresh to reconnect.');}
}
$('reader-tabs').addEventListener('click', event => {
  const button = event.target.closest('[role=tab]'); if (button) setTab(button.dataset.tab);
});
$('reader-tabs').addEventListener('keydown', event => {
  if (!['ArrowRight', 'ArrowLeft', 'Home', 'End'].includes(event.key)) return;
  const tabs = [...$('reader-tabs').querySelectorAll('[role=tab]')].filter(tab => !tab.disabled);
  const current = tabs.findIndex(tab => tab.dataset.tab === selectedTab);
  let index = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (current + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
  event.preventDefault(); setTab(tabs[index].dataset.tab, true);
});
$('ask-audience').addEventListener('change', event => {$('audience').disabled = event.target.checked;});
$('course-form').addEventListener('submit', async event => {
  event.preventDefault(); if (busy) return; clearError(); setBusy(true); clearTimeout(timer);
  try {
    const payload = {topic: $('topic').value, style: $('style').value, ask_style: $('ask-style').checked};
    if (!$('ask-audience').checked) payload.audience = $('audience').value;
    const task = await api('courses', 'POST', {payload});
    reference = task.reference_id || task.task_id; localStorage.setItem('rutvi-course-reference', reference);
    cursor = 0; events = []; artifact = null; artifactSignature = null; checkpoint = null; lastStatus = 'queued';
    $('download').hidden = true; $('reader-title').textContent = 'Your course is taking shape'; $('reader-subtitle').textContent = 'The agents are researching, planning, writing, and reviewing.';
    $('panel-overview').replaceChildren(node('p', 'Course generation is underway. Follow progress in the sidebar; your lessons will appear here when the review finishes.', 'content-intro'));
    for (const tab of ['lesson-1', 'lesson-2', 'quiz']) $('tab-' + tab).disabled = true;
    setTab('overview'); $('reference').hidden = false; $('reference').textContent = 'Task ' + reference; await poll();
  } catch (error) {setBusy(false); showError(error.message);}
});
$('answer-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = event.target.querySelector('button'); button.disabled = true; clearError();
  try {
    const payload = Object.fromEntries(new FormData(event.target));
    await api('tasks/' + encodeURIComponent(reference) + '/resume', 'POST', {checkpoint_id: checkpoint.checkpoint_id, response_id: crypto.randomUUID(), payload});
    checkpoint = null; $('question').hidden = true; clearTimeout(timer); await poll();
  } catch (error) {showError(error.message);} finally {button.disabled = false;}
});
$('cancel').addEventListener('click', async () => {
  clearError(); $('cancel').disabled = true;
  try {await api('tasks/' + encodeURIComponent(reference), 'DELETE'); clearTimeout(timer); await poll();}
  catch (error) {showError(error.message);} finally {$('cancel').disabled = false;}
});
(async () => {
  setBusy(false);
  try {
    const session = await api('session'); csrf = session.csrf; sources = session.sources || []; renderSources();
    configuredProviderBadge = session.provider === 'demonstration' ? 'Demonstration · sample responses' : 'Real AI · ' + session.model;
    $('provider').textContent = configuredProviderBadge; $('generate').disabled = false;
    reference = localStorage.getItem('rutvi-course-reference');
    if (reference) {$('reference').hidden = false; $('reference').textContent = 'Task ' + reference; await poll();}
  } catch (error) {$('provider').textContent = 'Unavailable'; showError(error.message);}
})();
