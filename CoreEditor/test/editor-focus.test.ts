import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing } from '../editor/live';
import { setPreviewExport } from '../editor/mode';
import { documentHTML } from '../editor/export';
import { activeBlockRange, applyDisplayModes, displayExtensions } from '../editor/focus';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string, anchor = 0) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc,
    selection: EditorSelection.cursor(anchor),
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, ...displayExtensions(), history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

/** jsdom 视口可能跳过被替换的块，用 posAtDOM 映射回文档行号（0 基）。 */
function dimmedLines(view: EditorView) {
  return Array.from(view.contentDOM.querySelectorAll('.cm-line'))
    .filter(node => node.classList.contains('cm-focus-dim'))
    .map(node => view.state.doc.lineAt(view.posAtDOM(node, 0)).number - 1)
    .sort((left, right) => left - right);
}

type DispatchSpec = { effects?: { value?: { y?: string; yMargin?: number } }[] };

function captureDispatch(view: EditorView) {
  const captured: DispatchSpec[] = [];
  const original = view.dispatch.bind(view) as (...args: unknown[]) => void;
  view.dispatch = ((...specs: unknown[]) => {
    captured.push(...specs as DispatchSpec[]);
    original(...specs);
  }) as typeof view.dispatch;
  return captured;
}

function centerScrolls(captured: DispatchSpec[]) {
  return captured.flatMap(spec => spec.effects ?? []).filter(effect => effect.value?.y === 'center');
}

const paragraphs = '甲\n\n乙\n\n丙';

describe('Inkpot 专注与打字机模式', () => {
  test('淡化当前段落以外的可见行，光标切换立即跟随，不修改文档或历史', () => {
    const { view, read } = editor(paragraphs, paragraphs.indexOf('乙'));
    applyDisplayModes(view, { focus: true });
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    view.dispatch({ selection: { anchor: paragraphs.indexOf('丙') } });
    expect(dimmedLines(view)).toEqual([0, 1, 2, 3]);
    view.dispatch({ selection: { anchor: 0 } });
    expect(dimmedLines(view)).toEqual([1, 2, 3, 4]);
    expect(read()).toBe(paragraphs);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('活动块覆盖整个列表项、代码块、表格与公式块，标题只保持当前行', () => {
    const text = '# 标题\n\n- 一\n- 二\n- 三\n\n```js\nlet a = 1\nlet b = 2\n```\n\n正文';
    const { view } = editor(text, 0);
    const doc = view.state.doc;
    const lines = text.split('\n').map((_line, index) => doc.line(index + 1));
    const span = (number: number) => ({ from: lines[number].from, to: lines[number].to });
    const position = (needle: string) => text.indexOf(needle);

    expect(activeBlockRange(view.state, position('标题'))).toEqual(span(0));
    // 列表项逐项独立：光标在第二项，其余项淡化。
    expect(activeBlockRange(view.state, position('二'))).toEqual(span(3));
    // 围栏代码块整体保持正常，含首尾围栏。
    expect(activeBlockRange(view.state, position('let b'))).toEqual({ from: lines[6].from, to: lines[9].to });
    applyDisplayModes(view, { focus: true });
    view.dispatch({ selection: { anchor: position('let b') } });
    expect(dimmedLines(view)).toEqual([0, 1, 2, 3, 4, 5, 10, 11]);
  });

  test('表格与公式块整体保持正常，空行只保持当前行', () => {
    const table = '前文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n后文';
    const tableView = editor(table, table.indexOf('| 1 |'));
    expect(activeBlockRange(tableView.view.state, table.indexOf('| 1 |'))).toEqual({
      from: tableView.view.state.doc.line(3).from, to: tableView.view.state.doc.line(5).to,
    });
    applyDisplayModes(tableView.view, { focus: true });
    expect(dimmedLines(tableView.view)).toEqual([0, 1, 5, 6]);

    const math = '前文\n\n$$\nE = mc^2\n$$\n\n后文';
    const mathView = editor(math, math.indexOf('E ='));
    expect(activeBlockRange(mathView.view.state, math.indexOf('E ='))).toEqual({
      from: mathView.view.state.doc.line(3).from, to: mathView.view.state.doc.line(5).to,
    });
    applyDisplayModes(mathView.view, { focus: true });
    expect(dimmedLines(mathView.view)).toEqual([0, 1, 5, 6]);

    // 空行不属于任何段落：只保持当前行，相邻段落淡化。
    const blankView = editor('甲\n\n乙', 2);
    applyDisplayModes(blankView.view, { focus: true });
    expect(dimmedLines(blankView.view)).toEqual([0, 2]);
  });

  test('组合输入期间不重建装饰，结束后刷新一次', async () => {
    const { view } = editor(paragraphs, paragraphs.indexOf('乙'));
    applyDisplayModes(view, { focus: true });
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    view.focus();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    expect(view.compositionStarted).toBe(true);
    view.dispatch({ selection: { anchor: 0 } });
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 100));
    expect(dimmedLines(view)).toEqual([1, 2, 3, 4]);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('关闭专注模式移除全部淡化，开关不进入撤销历史', () => {
    const { view, read } = editor(paragraphs, paragraphs.indexOf('乙'));
    applyDisplayModes(view, { focus: true, typewriter: false });
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    applyDisplayModes(view, { focus: false });
    expect(dimmedLines(view)).toEqual([]);
    expect(read()).toBe(paragraphs);
    expect(undoDepth(view.state)).toBe(0);
    // 模块状态跟随最后一次设置：新视图沿用专注模式偏好，模拟打开文档后原生同步前的初始状态。
    const next = editor('丙\n\n丁', 0);
    applyDisplayModes(next.view, { focus: true });
    expect(dimmedLines(next.view)).toEqual([1, 2]);
    applyDisplayModes(next.view, { focus: false });
  });

  test('打字机模式在选区移动与输入后居中光标行，关闭或导出时不滚动', () => {
    const { view } = editor(paragraphs, 0);
    const captured = captureDispatch(view);
    view.dispatch({ selection: { anchor: paragraphs.indexOf('乙') } });
    expect(centerScrolls(captured)).toHaveLength(0);
    applyDisplayModes(view, { typewriter: true });
    captured.length = 0;
    view.dispatch({ selection: { anchor: paragraphs.indexOf('丙') } });
    const scrolls = centerScrolls(captured);
    expect(scrolls).toHaveLength(1);
    expect(scrolls[0]?.value?.yMargin).toBe(0);
    captured.length = 0;
    view.dispatch({ changes: { from: paragraphs.indexOf('丙'), insert: '丁' } });
    expect(centerScrolls(captured)).toHaveLength(1);
    captured.length = 0;
    applyDisplayModes(view, { typewriter: false });
    view.dispatch({ selection: { anchor: 0 } });
    expect(centerScrolls(captured)).toHaveLength(0);
    // 导出期间原生临时移动选区，不得滚动。
    applyDisplayModes(view, { typewriter: true });
    view.dispatch({ effects: setPreviewExport.of(true) });
    captured.length = 0;
    view.dispatch({ selection: { anchor: paragraphs.indexOf('乙') } });
    expect(centerScrolls(captured)).toHaveLength(0);
    view.dispatch({ effects: setPreviewExport.of(false) });
    captured.length = 0;
    view.dispatch({ selection: { anchor: 0 } });
    expect(centerScrolls(captured)).toHaveLength(1);
    // 只有输入本身进入撤销历史，滚动事务不产生撤销记录。
    expect(undoDepth(view.state)).toBe(1);
  });

  test('导出的 HTML 不携带淡化效果，导出后视口恢复', async () => {
    const { view, read } = editor(paragraphs, paragraphs.indexOf('乙'));
    applyDisplayModes(view, { focus: true });
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    const html = await documentHTML(view, 'html');
    expect(html).not.toContain('cm-focus-dim');
    expect(dimmedLines(view)).toEqual([0, 1, 3, 4]);
    expect(read()).toBe(paragraphs);
    expect(undoDepth(view.state)).toBe(0);
  });
});
