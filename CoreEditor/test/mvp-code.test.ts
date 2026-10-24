import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { defaultKeymap, history, redo, undo, undoDepth } from '@codemirror/commands';
import { SearchQuery, setSearchQuery } from '@codemirror/search';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';
import { searchCommands } from '../mvp/search';

const views: EditorView[] = [];
function editor(text: string, position = 0, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, selection: EditorSelection.cursor(position),
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history(), keymap.of(defaultKeymap), EditorState.readOnly.of(readOnly)],
  }) });
  views.push(view);
  view.focus();
  return {
    view, read: () => source.read(view.state),
    press(key: string, shiftKey = false, mod = false) {
      const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform);
      view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key,
        keyCode: ({ Enter: 13, Tab: 9, Backspace: 8, Delete: 46, Escape: 27, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39 } as Record<string, number>)[key],
        shiftKey, metaKey: mod && mac, ctrlKey: mod && !mac, bubbles: true, cancelable: true,
      }));
    },
  };
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

describe('MVP 代码块', () => {
  test.each(['```', '````', '~~~'])('闭合的 %s 显示代码区域，光标进入不展开整块，切换模式保留原始字节', fence => {
    const original = `${fence}unknown title=x\r\n\t**中文**  \n# 字面\r\n${fence}\n尾`;
    const { view, read } = editor(original);
    expect(view.contentDOM.querySelectorAll('.cm-mvp-code')).toHaveLength(4);
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')?.textContent).toBe('unknown title=x');
    expect(view.contentDOM.textContent).not.toContain(fence);
    view.dispatch({ selection: { anchor: view.state.doc.line(2).from + 3 } });
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')).not.toBeNull();
    expect(view.contentDOM.querySelector('.cm-mvp-heading1')).toBeNull();
    expect(read()).toBe(original);
    const selection = view.state.selection;
    toggleSourceMode(view);
    expect(view.contentDOM.querySelector('.cm-mvp-code')).toBeNull();
    expect(view.contentDOM.textContent).toContain(fence);
    toggleSourceMode(view);
    expect(view.state.selection.eq(selection)).toBe(true);
    expect(undoDepth(view.state)).toBe(0);
    expect(read()).toBe(original);
  });

  test('点击语言仅展开首行，修改后回车回到代码，撤销保留正文与行尾', () => {
    const original = '```old title=x\r\n\t代码\n```';
    const { view, read, press } = editor(original);
    view.contentDOM.querySelector<HTMLButtonElement>('.cm-mvp-code-language')?.click();
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('old title=x');
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')).toBeNull();
    expect(view.contentDOM.querySelectorAll('.cm-mvp-code')).toHaveLength(3);
    view.dispatch({ ...view.state.replaceSelection('new title=x'), userEvent: 'input.type' });
    press('Enter');
    expect(view.state.selection.main.head).toBe(view.state.doc.line(2).from);
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')?.textContent).toBe('new title=x');
    expect(read()).toBe('```new title=x\r\n\t代码\n```');
    undo(view);
    expect(read()).toBe(original);
  });

  test.each(['Enter', 'Escape'])('语言仍处于选中状态时按 %s 返回代码，不替换或删除语言', key => {
    const original = '```python\n代码\n```';
    const { view, read, press } = editor(original);
    view.contentDOM.querySelector<HTMLButtonElement>('.cm-mvp-code-language')?.click();
    press(key);
    expect(read()).toBe(original);
    expect(view.state.selection.main.head).toBe(view.state.doc.line(2).from);
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')?.textContent).toBe('python');
    expect(undoDepth(view.state)).toBe(0);
  });

  test('没有正文行的空代码块退出语言编辑时不自动插入空行', () => {
    const original = '```js\n```';
    const { view, read, press } = editor(original);
    view.contentDOM.querySelector<HTMLButtonElement>('.cm-mvp-code-language')?.click();
    press('Escape');
    expect(read()).toBe(original);
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')?.textContent).toBe('js');
    expect(undoDepth(view.state)).toBe(0);
  });

  test.each(['```', '```js', '````lang'])('自动配对后的 %s 回车仍创建代码块', opening => {
    const fence = /^`+/.exec(opening)?.[0] ?? '';
    const paired = opening + fence;
    const { view, read, press } = editor(paired, opening.length);
    press('Enter');
    expect(read()).toBe(`${opening}\n\n${fence}`);
    expect(view.state.selection.main.head).toBe(opening.length + 1);
    undo(view);
    expect(read()).toBe(paired);
  });

  test.each(['```', '```js', '````lang', '~~~python'])('输入 %s 回车创建可编辑代码块，后续文字保持在围栏之外', opening => {
    const { view, read, press } = editor(opening + '\n尾', opening.length);
    const fence = /^(`+|~+)/.exec(opening)?.[0] ?? '';
    press('Enter');
    expect(read()).toBe(`${opening}\n\n${fence}\n尾`);
    expect(view.state.selection.main.head).toBe(opening.length + 1);
    expect(view.contentDOM.querySelector('.cm-mvp-code-language')).not.toBeNull();
    undo(view);
    expect(read()).toBe(opening + '\n尾');
    redo(view);
    expect(read()).toBe(`${opening}\n\n${fence}\n尾`);
  });

  test('代码中回车保留制表符和尾随空格，Tab 与 Shift+Tab 缩进可撤销', () => {
    const original = '```\r\n\t中文  \n```';
    const { view, read, press } = editor(original);
    view.dispatch({ selection: { anchor: view.state.doc.line(2).to } });
    press('Enter');
    expect(read()).toBe('```\r\n\t中文  \r\n\t\n```');
    undo(view);
    expect(read()).toBe(original);
    view.dispatch({ selection: { anchor: view.state.doc.line(2).from } });
    press('Tab');
    expect(view.state.doc.line(2).text).toBe('\t\t中文  ');
    press('Tab', true);
    expect(view.state.doc.line(2).text).toBe('\t中文  ');
  });

  test('返回正文不修改已有后文，文末退出只新增所需换行且可撤销', () => {
    const original = '```\n代码\n```\n后文';
    const first = editor(original, 5);
    first.press('Enter', false, true);
    expect(first.view.state.selection.main.head).toBe(first.view.state.doc.line(4).from);
    expect(first.read()).toBe(original);
    expect(undoDepth(first.view.state)).toBe(0);
    const last = editor('```\n代码\n```', 5);
    last.press('Enter', false, true);
    expect(last.read()).toBe('```\n代码\n```\n');
    expect(last.view.state.selection.main.head).toBe(last.view.state.doc.length);
    undo(last.view);
    expect(last.read()).toBe('```\n代码\n```');
  });

  test('空代码块可用退格移除，非空内容边界不吞掉围栏', () => {
    const empty = editor('```js\n\n```', 6);
    empty.press('Backspace');
    expect(empty.read()).toBe('');
    undo(empty.view);
    expect(empty.read()).toBe('```js\n\n```');
    const nonempty = editor('```\n文字\n```', 4);
    nonempty.press('Backspace');
    expect(nonempty.read()).toBe('```\n文字\n```');
    nonempty.view.dispatch({ selection: { anchor: 6 } });
    nonempty.press('Delete');
    expect(nonempty.read()).toBe('```\n文字\n```');
  });

  test('多行缩进只改变代码正文，保留反向选区、围栏和撤销', () => {
    const original = '```\r\n甲\n乙\r\n```';
    const { view, read, press } = editor(original);
    view.dispatch({ selection: EditorSelection.single(view.state.doc.line(3).to, view.state.doc.line(2).from) });
    press('Tab');
    expect(read()).toBe('```\r\n  甲\n  乙\r\n```');
    expect(view.state.selection.main.anchor).toBeGreaterThan(view.state.selection.main.head);
    press('Tab', true);
    expect(read()).toBe(original);
    undo(view);
    expect(read()).toBe('```\r\n  甲\n  乙\r\n```');
    undo(view);
    expect(read()).toBe(original);
  });

  test('左右键越过代码块边界时定位正文，不停在隐藏围栏', () => {
    const original = '前文\n```\n代码\n```\n后文';
    const { view, read, press } = editor(original, 7);
    press('ArrowLeft');
    expect(view.state.selection.main.head).toBe(view.state.doc.line(1).to);
    view.dispatch({ selection: { anchor: view.state.doc.line(3).to } });
    press('ArrowRight');
    expect(view.state.selection.main.head).toBe(view.state.doc.line(5).from);
    expect(read()).toBe(original);
  });

  test.each(['ArrowRight', 'Escape'])('文末按 %s 导航不补换行或改变未保存状态', key => {
    const original = '```\n代码\n```';
    const { view, read, press } = editor(original, 6);
    press(key);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('相邻代码块之间向前导航时回到前一块正文，而非隐藏闭围栏', () => {
    const original = '```\n前\n```\n```\n后\n```';
    const { view, read, press } = editor(original);
    view.dispatch({ selection: { anchor: view.state.doc.line(5).from } });
    press('ArrowLeft');
    expect(view.state.selection.main.head).toBe(view.state.doc.line(2).to);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('代码中的反向选区换行只替换所选内容，保留前后原文与围栏', () => {
    const { view, read, press } = editor('```\r\n  前中后\n```');
    const line = view.state.doc.line(2);
    view.dispatch({ selection: EditorSelection.single(line.from + 4, line.from + 3) });
    press('Enter');
    expect(read()).toBe('```\r\n  前\r\n  后\n```');
    undo(view);
    expect(read()).toBe('```\r\n  前中后\n```');
  });

  test.each(['> ', '- '])('嵌套在 %s 中的代码块保留父级，续行不生成正文列表', prefix => {
    const body = prefix === '- ' ? '  ' : prefix;
    const text = `${prefix}\x60\x60\x60js\n${body}代码\n${body}\x60\x60\x60`;
    const { view, read, press } = editor(text);
    view.dispatch({ selection: { anchor: view.state.doc.line(2).to } });
    press('Enter');
    expect(read()).toBe(`${prefix}\x60\x60\x60js\n${body}代码\n${body}\n${body}\x60\x60\x60`);
  });

  test.each([
    ['  ```\nx\n  ```', '  ```\nx\n\n  ```'],
    ['>   ```\n> x\n>   ```', '>   ```\n> x\n> \n>   ```'],
  ])('围栏前额外空格不会变成代码的新增缩进：%s', (text, expected) => {
    const { view, read, press } = editor(text);
    view.dispatch({ selection: { anchor: view.state.doc.line(2).to } });
    press('Enter');
    expect(read()).toBe(expected);
  });

  test('搜索围栏可以看见当前匹配，移动选区后恢复代码区域', () => {
    const original = '```js\n代码\n```';
    const { view, read } = editor(original);
    searchCommands.find(view);
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '```', literal: true })) });
    searchCommands.findNext(view);
    expect(view.contentDOM.textContent).toContain('```js');
    searchCommands.findNext(view);
    expect(view.contentDOM.querySelector('.cm-mvp-code-footer')).toBeNull();
    view.dispatch({ selection: { anchor: 6 } });
    expect(view.contentDOM.querySelector('.cm-mvp-code-footer')).not.toBeNull();
    expect(read()).toBe(original);
  });

  test('未闭合代码保留源码，源码模式不自动补围栏', () => {
    const first = editor('```js\n正文');
    expect(first.view.contentDOM.querySelector('.cm-mvp-code')).toBeNull();
    expect(first.read()).toBe('```js\n正文');
    const raw = editor('```js', 5);
    toggleSourceMode(raw.view);
    raw.press('Enter');
    expect(raw.read()).toBe('```js\n');
  });

  test('只读与组合输入期间不会创建或退出代码块', () => {
    const locked = editor('```', 3, true);
    locked.press('Enter');
    expect(locked.read()).toBe('```');
    const composing = editor('```', 3);
    composing.view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    composing.press('Enter');
    expect(composing.read()).toBe('```');
    composing.view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
  });
});
