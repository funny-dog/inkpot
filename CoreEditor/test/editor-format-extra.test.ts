import { afterEach, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undo } from '@codemirror/commands';
import { SearchQuery, setSearchQuery } from '@codemirror/search';
import { syntaxTree } from '@codemirror/language';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { formatCommands } from '../editor/format';
import { searchCommands } from '../editor/search';

const views: EditorView[] = [];
function editor(text: string, anchor = 0, head = anchor, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, selection: EditorSelection.single(anchor, head),
    extensions: [...source.extensions, ...writingExtensions, history(), EditorState.readOnly.of(readOnly)],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

const shortcuts = [
  ['strikethrough', 'X', '~~中文~~'], ['inlineCode', 'e', '`中文`'], ['link', 'k', '[中文](url)'],
  ['blockquote', '>', '> 中文'], ['taskList', '9', '- [ ] 中文'], ['codeBlock', 'C', '```\n中文\n```'],
  ['horizontalRule', 'H', '中文\n\n---\n\n'],
];
test.each(shortcuts)('%s 快捷键与命令一致且独立撤销', (name, key, expected) => {
  const { view, read } = editor('中文', 0, 2);
  view.focus();
  const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform);
  view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
    key, keyCode: key === '>' ? 190 : key.toUpperCase().charCodeAt(0), shiftKey: key === key.toUpperCase(),
    metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true,
  }));
  expect(read()).toBe(expected);
  undo(view);
  expect(read()).toBe('中文');
  formatCommands[name]?.(view);
  expect(read()).toBe(expected);
});

test.each([['strikethrough', '~~'], ['inlineCode', '`']])('%s 保持反向选区且能移除', (name, mark) => {
  const { view, read } = editor('前中文后', 3, 1);
  formatCommands[name]?.(view);
  expect(read()).toBe(`前${mark}中文${mark}后`);
  expect(view.state.selection.main.anchor).toBeGreaterThan(view.state.selection.main.head);
  formatCommands[name]?.(view);
  expect(read()).toBe('前中文后');
});

test.each(['`未闭合', '含``反引号', ' 首尾空格 '])('行内代码选择围栏并保留内容：%s', text => {
  const { view, read } = editor(text, 0, text.length);
  formatCommands.inlineCode?.(view);
  expect(syntaxTree(view.state).topNode.firstChild?.firstChild?.name).toBe('InlineCode');
  formatCommands.inlineCode?.(view);
  expect(read()).toBe(text);
});

test.each(['strikethrough', 'inlineCode', 'codeBlock', 'link'])('%s 支持空文档插入与再次移除', name => {
  const { view, read } = editor('');
  formatCommands[name]?.(view);
  expect(read().length).toBeGreaterThan(0);
  formatCommands[name]?.(view);
  expect(read()).toBe('');
});

test('链接选中地址便于替换，移除时保留标签格式', () => {
  const { view, read } = editor('**文字**', 0, 6);
  formatCommands.link?.(view);
  expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('url');
  formatCommands.link?.(view);
  expect(read()).toBe('**文字**');
});

test.each(['blockquote', 'taskList', 'codeBlock'])('%s 切换保留混合行尾与逐次撤销', name => {
  const original = '甲\r\n乙\n尾';
  const { view, read } = editor(original, 0, 3);
  formatCommands[name]?.(view);
  const formatted = read();
  expect(formatted).toContain('甲\r\n');
  formatCommands[name]?.(view);
  expect(read()).toBe(original);
  undo(view);
  expect(read()).toBe(formatted);
  undo(view);
  expect(read()).toBe(original);
});

test('任务列表转换不遗留旧复选框，引用保留列表内容', () => {
  const { view, read } = editor('- [x] 完成\n- 普通', 0, 12);
  formatCommands.taskList?.(view);
  expect(read()).toBe('- [x] 完成\n- [ ] 普通');
  formatCommands.bulletList?.(view);
  expect(read()).toBe('- 完成\n- 普通');
  formatCommands.blockquote?.(view);
  expect(read()).toBe('> - 完成\n> - 普通');
});

test('代码块避开选中文本中的围栏，分隔线不覆盖选区', () => {
  const code = editor('正文\n```\n代码', 0, 9);
  formatCommands.codeBlock?.(code.view);
  expect(code.read()).toBe('````\n正文\n```\n代码\n````');
  const rule = editor('前选中文字后', 1, 5);
  formatCommands.horizontalRule?.(rule.view);
  expect(rule.read()).toBe('前选中文字\n\n---\n\n后');
});

test('所有新增格式命令在只读时保持原文', () => {
  const { view, read } = editor('中文', 0, 2, true);
  for (const [name] of shortcuts) expect(formatCommands[name]?.(view)).toBe(false);
  expect(read()).toBe('中文');
});

function type(view: EditorView, text: string, userEvent = 'input.type') {
  const { from, to } = view.state.selection.main;
  const insert = () => view.state.update({ changes: { from, to, insert: text }, selection: { anchor: from + text.length }, userEvent });
  const handled = view.state.facet(EditorView.inputHandler).some(handler => handler(view, from, to, text, insert));
  if (!handled) view.dispatch(insert());
  return handled;
}

test.each([['(', ')'], ['[', ']'], ['"', '"'], ['`', '`'], ['*', '*']])('%s 自动闭合、包住反向选区并保留原始行尾', (open, close) => {
  const empty = editor('');
  expect(type(empty.view, open)).toBe(true);
  expect(empty.read()).toBe(open + close);
  expect(empty.view.state.selection.main.head).toBe(1);
  undo(empty.view);
  expect(empty.read()).toBe('');
  const original = '甲\r\n乙';
  const selected = editor(original, 3, 0);
  expect(type(selected.view, open)).toBe(true);
  expect(selected.read()).toBe(open + original + close);
  expect(selected.view.state.selection.main.anchor).toBe(4);
  expect(selected.view.state.selection.main.head).toBe(1);
});

test('闭合符越过已有符号，连续星号与反引号可以扩展', () => {
  const { view, read } = editor('()', 1);
  type(view, ')');
  expect(read()).toBe('()');
  expect(view.state.selection.main.head).toBe(2);
  for (const mark of ['*', '`']) {
    const repeated = editor('');
    type(repeated.view, mark);
    type(repeated.view, mark);
    expect(repeated.read()).toBe(mark.repeat(4));
    type(repeated.view, '字');
    type(repeated.view, mark);
    type(repeated.view, mark);
    expect(repeated.read()).toBe(`${mark.repeat(2)}字${mark.repeat(2)}`);
  }
});

test('自动配对忽略组合输入、转义、粘贴、多字符及只读输入', () => {
  const composing = editor('');
  composing.view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
  expect(type(composing.view, '(')).toBe(false);
  expect(composing.read()).toBe('(');
  composing.view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
  for (const event of ['input.paste', 'input.type.compose']) {
    const pasted = editor('');
    expect(type(pasted.view, '*', event)).toBe(false);
    expect(pasted.read()).toBe('*');
  }
  const escaped = editor('\\', 1);
  expect(type(escaped.view, '*')).toBe(false);
  const multiple = editor('');
  expect(type(multiple.view, '([')).toBe(false);
  const locked = editor('只读', 0, 2, true);
  const transaction = () => locked.view.state.update({ userEvent: 'input.type' });
  expect(locked.view.state.facet(EditorView.inputHandler).some(handler => handler(locked.view, 0, 2, '*', transaction))).toBe(false);
  expect(locked.read()).toBe('只读');
});

function search(view: EditorView, text: string, replacement = '') {
  searchCommands.find(view);
  function field(name: string) {
    const input = view.dom.querySelector<HTMLInputElement>(`input[name=${name}]`);
    if (input === null) throw new Error(`缺少搜索输入 ${name}`);
    return input;
  }
  function button(name: string) {
    const button = view.dom.querySelector<HTMLButtonElement>(`button[name=${name}]`);
    if (button === null) throw new Error(`缺少搜索按钮 ${name}`);
    button.click();
  }
  function set(name: string, value: string) {
    field(name).value = value;
    field(name).dispatchEvent(new InputEvent('input', { bubbles: true }));
  }
  set('search', text);
  set('replace', replacement);
  return { toggle: (name: string) => field(name).click(),
    replaceAll: () => button('replaceAll'), close: () => button('close'), field, set };
}

test('大小写与整词开关组合替换、关闭重开保留选项且可撤销', () => {
  const { view, read } = editor('Cat cat cats\r\nCAT');
  const panel = search(view, 'cat', '字');
  panel.toggle('caseSensitive');
  panel.toggle('wholeWord');
  panel.replaceAll();
  expect(read()).toBe('Cat 字 cats\r\nCAT');
  undo(view);
  panel.close();
  searchCommands.find(view);
  expect(panel.field('caseSensitive').checked).toBe(true);
  expect(panel.field('wholeWord').checked).toBe(true);
  panel.toggle('caseSensitive');
  panel.replaceAll();
  expect(read()).toBe('字 字 cats\r\n字');
});

test('正则支持捕获替换，无效表达式提示错误且不改文档', () => {
  const { view, read } = editor('a1 a22\r\n尾');
  const panel = search(view, 'a(\\d+)', '[$1]');
  panel.toggle('regexp');
  panel.replaceAll();
  expect(read()).toBe('[1] [22]\r\n尾');
  undo(view);
  expect(read()).toBe('a1 a22\r\n尾');
  panel.set('search', '[');
  panel.replaceAll();
  expect(view.dom.querySelector('[role=status]')?.textContent).toBe('正则表达式无效');
  expect(panel.field('search').getAttribute('aria-invalid')).toBe('true');
  expect(read()).toBe('a1 a22\r\n尾');
  view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: 'a', caseSensitive: true, wholeWord: true })) });
  expect(panel.field('regexp').checked).toBe(false);
  expect(panel.field('caseSensitive').checked).toBe(true);
  expect(panel.field('wholeWord').checked).toBe(true);
});
