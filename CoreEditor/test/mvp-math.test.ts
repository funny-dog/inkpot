import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undo, undoDepth } from '@codemirror/commands';
import { findNext, SearchQuery, setSearchQuery } from '@codemirror/search';
import { syntaxTree } from '@codemirror/language';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';
import { blockMathTagName, inlineMathTagName, mathCommands, useKatexForTests } from '../mvp/math';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

const renders: { tex: string; display: boolean }[] = [];
useKatexForTests({
  render(tex, element, options) {
    renders.push({ tex, display: options.displayMode });
    element.textContent = `公式:${tex}`;
    element.classList.add('fake-katex');
  },
});

function editor(text: string, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history(), EditorState.readOnly.of(readOnly)],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

async function flushed() {
  await new Promise(resolve => setTimeout(resolve, 0));
}

function hasNode(view: EditorView, name: string) {
  let found = false;
  syntaxTree(view.state).iterate({ enter(node) { if (node.name === name) found = true; } });
  return found;
}

const original = '前文 $x^2$ 居中\r\n\r\n$$\r\nE = mc^2\n$$\r\n\r\n尾行';
const plain = original.replace(/\r\n/g, '\n');

describe('MVP 公式', () => {
  test('块级与行内公式实时渲染，光标进入局部展开源码，原文与历史不变', async () => {
    const { view, read } = editor(original);
    await flushed();
    const widgets = view.dom.querySelectorAll('.cm-mvp-math');
    expect(widgets).toHaveLength(2);
    expect(renders.at(-2)).toEqual({ tex: 'x^2', display: false });
    expect(renders.at(-1)).toEqual({ tex: 'E = mc^2', display: true });
    expect(widgets[0].classList.contains('cm-mvp-math-block')).toBe(false);
    expect(widgets[1].classList.contains('cm-mvp-math-block')).toBe(true);
    // 点击公式进入编辑：源码展开、公式隐藏；移动光标后恢复渲染。
    widgets[1].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.dom.querySelector('.cm-mvp-math-block')).toBeNull();
    expect(view.state.selection.main.head).toBe(plain.indexOf('E =') - 1);
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('.cm-mvp-math-block')).not.toBeNull();
    // 键盘光标进入行内公式同样展开。
    view.dispatch({ selection: { anchor: plain.indexOf('x^2') } });
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(1);
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(2);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('货币、空白、转义与未闭合的 $ 保持原样，不渲染也不改文档', () => {
    const text = '价格 $5 和 $6 之间\n空 $ x$ 与 $x $\n转义 \\$x\\$ 与行中 $$x$$\n未闭合的段落\n$$\nE = mc^2\n';
    const { view, read } = editor(text);
    expect(view.dom.querySelector('.cm-mvp-math')).toBeNull();
    expect(hasNode(view, blockMathTagName)).toBe(false);
    expect(hasNode(view, inlineMathTagName)).toBe(false);
    expect(read()).toBe(text);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('搜索公式内容时展开源文，退出搜索导航后恢复渲染', async () => {
    const { view, read } = editor(original);
    await flushed();
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: 'mc^2' })) });
    findNext(view);
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(1);
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(2);
    expect(read()).toBe(original);
  });

  test('源码模式显示原始 LaTeX，切回实时模式恢复渲染；嵌套容器内保留源码', async () => {
    const nested = original + '\n\n> $$\n> a+b\n> $$\n';
    const { view, read } = editor(nested);
    await flushed();
    toggleSourceMode(view);
    expect(view.dom.querySelector('.cm-mvp-math')).toBeNull();
    toggleSourceMode(view);
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(2);
    expect(read()).toBe(nested);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('插入公式块在空行原位插入，其余位置用空行分隔，撤销精确恢复', () => {
    const empty = editor('正文\r\n\r\n尾行');
    empty.view.dispatch({ selection: { anchor: '正文\n\n'.length - 1 } });
    expect(mathCommands.insertMathBlock(empty.view)).toBe(true);
    expect(empty.read()).toBe('正文\r\n$$\r\n\r\n$$\r\n尾行');
    expect(empty.view.state.selection.main.head).toBe('正文\n$$\n'.length);
    undo(empty.view);
    expect(empty.read()).toBe('正文\r\n\r\n尾行');

    const middle = editor('正文 内容 尾行');
    middle.view.dispatch({ selection: { anchor: 2 } });
    expect(mathCommands.insertMathBlock(middle.view)).toBe(true);
    expect(middle.read()).toBe('正文\n\n$$\n\n$$\n\n 内容 尾行');
    undo(middle.view);
    expect(middle.read()).toBe('正文 内容 尾行');

    const start = editor('正文');
    start.view.dispatch({ selection: { anchor: 0 } });
    expect(mathCommands.insertMathBlock(start.view)).toBe(true);
    expect(start.read()).toBe('$$\n\n$$\n\n正文');
    undo(start.view);
    expect(start.read()).toBe('正文');

    const blank = editor('');
    expect(mathCommands.insertMathBlock(blank.view)).toBe(true);
    expect(blank.read()).toBe('$$\n\n$$');
    expect(blank.view.state.selection.main.head).toBe('$$\n'.length);
  });

  test('表格、代码块和列表内不插入公式块', () => {
    const { view } = editor('| a | b |\n| --- | --- |\n| c | d |');
    view.dispatch({ selection: { anchor: 5 } });
    expect(mathCommands.insertMathBlock(view)).toBe(false);
    const code = editor('```\ncode\n```');
    code.view.dispatch({ selection: { anchor: 4 } });
    expect(mathCommands.insertMathBlock(code.view)).toBe(false);
    const list = editor('- 项目');
    list.view.dispatch({ selection: { anchor: 2 } });
    expect(mathCommands.insertMathBlock(list.view)).toBe(false);
  });

  test('组合输入期间不重建公式装饰，确认后恢复渲染', async () => {
    const { view } = editor('正文\n');
    await flushed();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    view.dispatch({ changes: { from: 3, insert: '$x^2$' } });
    expect(view.dom.querySelector('.cm-mvp-math')).toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 120));
    expect(view.dom.querySelector('.cm-mvp-math')).not.toBeNull();
  });

  test('只读文档渲染公式且点击不进入编辑', async () => {
    const { view } = editor(original, true);
    await flushed();
    const widgets = view.dom.querySelectorAll('.cm-mvp-math');
    expect(widgets).toHaveLength(2);
    widgets[0].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.dom.querySelectorAll('.cm-mvp-math')).toHaveLength(2);
  });
});
