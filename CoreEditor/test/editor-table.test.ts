import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undo, redo, undoDepth } from '@codemirror/commands';
import { findNext, SearchQuery, setSearchQuery } from '@codemirror/search';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { isComposing } from '../editor/mode';
import { canTableCommand, tableCommands } from '../editor/table';
import { rowCells } from '../editor/table-model';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });
function editor(text: string, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history(), EditorState.readOnly.of(readOnly)],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
function input(view: EditorView, row: number, column: number) {
  const result = view.dom.querySelector<HTMLInputElement>(`input[data-row="${row}"][data-column="${column}"]`);
  if (result === null) throw new Error('缺少表格单元格');
  return result;
}
function type(target: HTMLInputElement, value: string, composing = false) {
  target.focus(); target.value = value; target.setSelectionRange(value.length, value.length);
  target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', isComposing: composing }));
}
function key(target: HTMLInputElement, value: string, shiftKey = false) {
  target.dispatchEvent(new KeyboardEvent('keydown', { key: value, shiftKey, bubbles: true, cancelable: true }));
}
const original = '前文\r\n\r\n| A |B|\r\n|:---|---:|\n| x | y |\r\n| z | q |\n\n后文';

describe('Inkpot 表格', () => {
  test('渲染不整齐表格、对齐及空单元格，导航和模式切换保持原文字节与历史', () => {
    const { view, read } = editor(original);
    expect(view.dom.querySelectorAll('.cm-inkpot-table table')).toHaveLength(1);
    expect(view.dom.querySelectorAll('th')).toHaveLength(2);
    expect(input(view, 0, 0).parentElement?.style.textAlign).toBe('left');
    expect(input(view, 0, 1).parentElement?.style.textAlign).toBe('right');
    input(view, 1, 1).focus(); input(view, 1, 1).select();
    view.dispatch({ selection: { anchor: 0 } });
    toggleSourceMode(view); expect(view.dom.querySelector('table')).toBeNull();
    toggleSourceMode(view); expect(view.dom.querySelector('table')).not.toBeNull();
    expect(read()).toBe(original); expect(undoDepth(view.state)).toBe(0);
  });

  test('仅替换当前单元格，保留其他空白、行尾和隐藏的多余列，撤销精确恢复', () => {
    const text = original.replace('| x | y |', '| x | y | 保留额外内容 |');
    const { view, read } = editor(text);
    type(input(view, 1, 0), '中文|内容');
    expect(read()).toBe(text.replace('| x |', '| 中文\\|内容 |'));
    expect(document.activeElement).toBe(input(view, 1, 0));
    undo(view); expect(read()).toBe(text);
    redo(view); expect(read()).toContain('中文\\|内容');
  });

  test('少列的行补齐目标单元格，不改写其他行；空格单元格仍可输入', () => {
    const text = 'a|b|c\r\n---|---|---\r\nx\n\n尾';
    const { view, read } = editor(text);
    type(input(view, 1, 2), '末列');
    expect(read()).toBe('a|b|c\r\n---|---|---\r\nx |  | 末列\n\n尾');
    undo(view); expect(read()).toBe(text);
    const blank = editor('| a | b |\n| --- | --- |\n|   |  |');
    type(input(blank.view, 1, 0), '空');
    expect(blank.read()).toBe('| a | b |\n| --- | --- |\n|   空|  |');
  });

  test('Tab、Shift+Tab、Enter 与 Esc 导航不修改原文，表格边界不补段落', () => {
    const { view, read } = editor(original);
    const first = input(view, 0, 0); first.focus();
    key(first, 'Tab'); expect(document.activeElement).toBe(input(view, 0, 1));
    key(input(view, 0, 1), 'Tab', true); expect(document.activeElement).toBe(first);
    key(first, 'Enter'); expect(document.activeElement).toBe(input(view, 1, 0));
    key(input(view, 1, 0), 'Escape'); expect(document.activeElement).toBe(view.contentDOM);
    expect(read()).toBe(original); expect(undoDepth(view.state)).toBe(0);
  });

  test('组合输入不提前写入或重建输入框，结束后一次写回并可撤销', () => {
    const { view, read } = editor(original);
    const target = input(view, 1, 0); target.focus();
    target.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    type(target, '候选中文', true);
    expect(isComposing(view)).toBe(true);
    expect(toggleSourceMode(view)).toBe(false);
    expect(tableCommands.tableRowBelow(view)).toBe(false);
    expect(read()).toBe(original); expect(input(view, 1, 0)).toBe(target);
    target.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    expect(isComposing(view)).toBe(false);
    expect(read()).toBe(original.replace('| x |', '| 候选中文 |'));
    expect(undoDepth(view.state)).toBe(1);
    undo(view); expect(read()).toBe(original);
  });

  test.each(['tableRowAbove', 'tableRowBelow', 'tableColumnBefore', 'tableColumnAfter', 'tableDeleteRow', 'tableDeleteColumn', 'tableAlignCenter'])('%s 只改变目标表格，独立撤销保留混合行尾', command => {
    const text = original.replace('| x | y |', '| x | y | 隐藏内容 |');
    const { view, read } = editor(text);
    input(view, 1, 0).focus();
    expect(tableCommands[command](view)).toBe(true);
    expect(read().startsWith('前文\r\n\r\n')).toBe(true);
    expect(read().endsWith('\n\n后文')).toBe(true);
    if (command !== 'tableDeleteRow') expect(read()).toContain('隐藏内容');
    expect(undoDepth(view.state)).toBe(1);
    undo(view); expect(read()).toBe(text);
  });

  test('保护表头与最后一列，删除最后一行后表头表格仍可继续增行', () => {
    const { view } = editor('| a |\n| --- |\n| b |');
    input(view, 0, 0).focus();
    expect(canTableCommand('tableDeleteRow', view)).toBe(false);
    expect(tableCommands.tableDeleteColumn(view)).toBe(false);
    input(view, 1, 0).focus();
    tableCommands.tableDeleteRow(view);
    expect(view.dom.querySelectorAll('tr')).toHaveLength(1);
    input(view, 0, 0).focus(); tableCommands.tableRowBelow(view);
    expect(view.dom.querySelectorAll('tr')).toHaveLength(2);
  });

  test('基础行内格式只渲染安全元素，代码、HTML 和嵌套容器不误作可编辑表格', () => {
    const { view } = editor('| **粗体** | *斜体* | `代码` | [链接](https://example.com) |\n|---|---|---|---|\n|<img onerror=evil>|x|y|z|');
    expect(view.dom.querySelector('th strong')?.textContent).toBe('粗体');
    expect(view.dom.querySelector('th em')?.textContent).toBe('斜体');
    expect(view.dom.querySelector('th code')?.textContent).toBe('代码');
    expect(view.dom.querySelector('th [role=link]')?.textContent).toBe('链接');
    expect(view.dom.querySelector('td img')).toBeNull();
    const nested = editor('```\n| a | b |\n|---|---|\n```\n\n> | a | b |\n> |---|---|');
    expect(nested.view.dom.querySelector('table')).toBeNull();
  });

  test('搜索隐藏表格标记时展开源文，退出搜索导航后恢复，原文不变', () => {
    const { view, read } = editor(original);
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: ':---' })) });
    findNext(view); expect(view.dom.querySelector('table')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('table')).not.toBeNull(); expect(read()).toBe(original);
  });

  test('插入表格是显式编辑且可以一次撤销，源码模式不启用行列操作', () => {
    const { view, read } = editor('正文\r\n尾\n');
    expect(tableCommands.insertTable(view)).toBe(true);
    expect(view.dom.querySelectorAll('th')).toHaveLength(2);
    expect(document.activeElement).toBe(input(view, 1, 0));
    undo(view); expect(read()).toBe('正文\r\n尾\n');
    const table = editor(original);
    input(table.view, 1, 0).focus(); toggleSourceMode(table.view);
    expect(tableCommands.tableRowBelow(table.view)).toBe(false);
  });

  test('只读表格不接受编辑或结构命令，位置移动后仍定位到正确的单元格', () => {
    const readonly = editor(original, true);
    expect(input(readonly.view, 1, 0).disabled).toBe(true);
    type(input(readonly.view, 1, 0), '不能修改');
    expect(readonly.read()).toBe(original);
    expect(tableCommands.insertTable(readonly.view)).toBe(false);
    const { view, read } = editor(original);
    view.dispatch({ changes: { from: 0, insert: '增加前文\n' } });
    type(input(view, 1, 1), '新内容');
    expect(read()).toContain('| x | 新内容 |');
  });

  test('转义管道与反斜杠按奇偶计数，不将转义的末尾管道误作边界', () => {
    expect(rowCells('| a\\|b | c |').map(cell => cell.text)).toEqual(['a\\|b', 'c']);
    expect(rowCells('a|b\\|').map(cell => cell.text)).toEqual(['a', 'b\\|']);
    expect(rowCells('a\\\\|b').map(cell => cell.text)).toEqual(['a\\\\', 'b']);
  });
  test('文末表格中 ⌘Enter 显式建立正文段落，独立撤销；空缺列操作定位到实际焦点', () => {
    const text = '| a | b | c |\n|---|---|---|\n|x|';
    const { view, read } = editor(text);
    const last = input(view, 1, 2); last.focus();
    tableCommands.tableColumnBefore(view);
    expect(input(view, 0, 2).value).toBe('');
    expect(input(view, 0, 3).value).toBe('c');
    undo(view); expect(read()).toBe(text);
    const target = input(view, 1, 0); target.focus();
    target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true, cancelable: true }));
    expect(read()).toBe(text + '\n\n');
    expect(document.activeElement).toBe(view.contentDOM);
    undo(view); expect(read()).toBe(text);
  });

  test('中心对齐和缩进表格正常显示，单元格的代码管道仍需正确转义', () => {
    const text = '  | a | b |\n  |:---:|---|\n  | `x\\|y` | z |';
    const { view, read } = editor(text);
    expect(input(view, 0, 0).parentElement?.style.textAlign).toBe('center');
    expect(view.dom.querySelector('td code')?.textContent).toBe('x\\|y');
    input(view, 1, 1).focus(); tableCommands.tableRowBelow(view);
    expect(read()).toContain('  | `x\\|y` | z |');
    undo(view); expect(read()).toBe(text);
  });

  test('逐字输入保留单词间空格与输入焦点，不把编辑中的空格当作布局删除', () => {
    const { view, read } = editor(original);
    const target = input(view, 1, 0); target.focus();
    for (const character of ' hello') type(target, target.value + character);
    expect(target.value).toBe('x hello');
    expect(document.activeElement).toBe(target);
    expect(read()).toBe(original.replace('| x |', '| x hello |'));
    undo(view); expect(read()).toBe(original);
  });

});
