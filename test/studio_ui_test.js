const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
class Element {
  constructor(tag) {this.tag = tag; this.children = []; this.attributes = {}; this.dataset = {};}
  set textContent(value) {this.children = [String(value)];}
  get textContent() {return this.children.map(item => typeof item === 'string' ? item : item.textContent).join('');}
  append(...items) {this.children.push(...items);}
  replaceChildren(...items) {this.children = items;}
  setAttribute(key, value) {this.attributes[key] = value;}
  addEventListener() {}
  focus() {this.focused = true;}
  querySelectorAll() {return this.children;}
}
function setup() {
  const ids = new Map();
  const document = {createElement: tag => new Element(tag), createTextNode: text => String(text), getElementById: id => ids.get(id)};
  const context = vm.createContext({document, URL, console});
  const source = fs.readFileSync('priv/studio/app.js', 'utf8');
  vm.runInContext(source.slice(0, source.indexOf("$('reader-tabs').addEventListener")) + '\nthis.ui = {markdown, inline, setTab};', context);
  return {context, ids, ui: context.ui};
}
function elements(root) {return [root, ...root.children.filter(item => item instanceof Element).flatMap(elements)];}
test('lesson markdown renders headings, emphasis, lists and code as semantic elements', () => {
  const {ui} = setup();
  const rendered = ui.markdown('## A heading\n\nA **strong** word and `code`.\n\n- First\n- Second\n\n```elixir\nIO.puts("hello")\n```');
  const tags = elements(rendered).map(item => item.tag);
  for (const tag of ['h3', 'strong', 'code', 'ul', 'li', 'pre']) assert.ok(tags.includes(tag), tag);
  assert.ok(rendered.textContent.includes('IO.puts("hello")'));
  assert.ok(!rendered.textContent.includes('**strong**'));
});
test('model HTML and unsafe links remain literal text, safe links get safe browser attributes', () => {
  const {ui} = setup();
  const rendered = ui.markdown('<img src=x onerror=alert(1)>\n\n[unsafe](javascript:alert) [reference](https://example.org/source)');
  assert.ok(rendered.textContent.includes('<img src=x onerror=alert(1)>'));
  assert.ok(!elements(rendered).some(item => item.tag === 'img' || item.tag === 'script'));
  const links = elements(rendered).filter(item => item.tag === 'a');
  assert.equal(links.length, 1);
  assert.equal(links[0].href, 'https://example.org/source');
  assert.equal(links[0].rel, 'noopener noreferrer');
});
test('reader navigation updates visible panel and accessible selected state, skips unavailable sections', () => {
  const {ids, ui} = setup();
  const list = new Element('div'); ids.set('reader-tabs', list);
  for (const name of ['overview', 'lesson-1', 'quiz']) {
    const tab = new Element('button'); tab.dataset.tab = name; tab.disabled = name === 'quiz';
    ids.set('tab-' + name, tab); ids.set('panel-' + name, new Element('section')); list.append(tab);
  }
  ui.setTab('lesson-1', true);
  assert.equal(ids.get('panel-lesson-1').hidden, false);
  assert.equal(ids.get('panel-overview').hidden, true);
  assert.equal(ids.get('tab-lesson-1').attributes['aria-selected'], 'true');
  assert.equal(ids.get('tab-lesson-1').tabIndex, 0);
  assert.equal(ids.get('tab-overview').tabIndex, -1);
  assert.equal(ids.get('tab-lesson-1').focused, true);
  ui.setTab('quiz');
  assert.equal(ids.get('tab-lesson-1').attributes['aria-selected'], 'true');
});
