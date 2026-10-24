import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { cursorCharLeft, cursorCharRight, deleteCharBackward, history, redo, undo, undoDepth } from '@codemirror/commands';
import { SearchQuery, setSearchQuery } from '@codemirror/search';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, sourceMode, toggleSourceMode } from '../editor/live';
import { formatCommands } from '../editor/format';
import { searchCommands } from '../editor/search';

const views: EditorView[] = [];
function editor(text: string, anchor = 0) {
  const source = sourceDocument(text);
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({
      doc: source.doc,
      selection: EditorSelection.cursor(anchor),
      extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()],
    }),
  });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function hiddenInline(view: EditorView) {
  return Array.from(view.contentDOM.querySelectorAll('.cm-inkpot-hidden-inline'), node => node.textContent);
}

describe('Inkpot 基础实时编辑', () => {
  test('标题和列表在光标进入后仍保持渲染，引用覆盖连续行，混合行尾不变', () => {
    const original = '# 标题\r\n- 无序\n\n3) 有序\r\n\n> 引用\n> 后一行';
    const { view, read } = editor(original);
    for (const anchor of [0, 3, 7, 14, 21, 27]) {
      view.dispatch({ selection: { anchor } });
      expect(view.contentDOM.querySelector('.cm-inkpot-heading1')?.textContent).toBe('标题');
      expect(Array.from(view.contentDOM.querySelectorAll('.cm-inkpot-list-marker'), node => node.textContent)).toEqual(['• ', '3. ']);
      expect(view.contentDOM.querySelectorAll('.cm-inkpot-quote')).toHaveLength(2);
      expect(read()).toBe(original);
    }
    expect(undoDepth(view.state)).toBe(0);
  });

  test('光标只展开所处行内元素，同段其他格式仍隐藏，反向选区也可编辑', () => {
    const { view, read } = editor('前 **粗体** 和 *斜体* 后');
    expect(hiddenInline(view)).toEqual(['**', '**', '*', '*']);
    view.dispatch({ selection: { anchor: 5 } });
    expect(hiddenInline(view)).toEqual(['*', '*']);
    view.dispatch({ selection: { anchor: 12 } });
    expect(hiddenInline(view)).toEqual(['**', '**']);
    view.dispatch({ selection: EditorSelection.single(14, 3) });
    expect(hiddenInline(view)).toEqual([]);
    expect(view.state.selection.main.anchor).toBe(14);
    expect(read()).toBe('前 **粗体** 和 *斜体* 后');
  });

  test('嵌套强调仅展开包含光标的元素，不解析代码或 HTML 中的伪标记', () => {
    const original = '**外层 *内层* 尾**\n`**代码**`\n```\n# 非标题\n- 非列表\n```\n<script>**字面**</script>';
    const { view, read } = editor(original, 3);
    expect(hiddenInline(view)).toEqual(['*', '*', '`', '`']);
    view.dispatch({ selection: { anchor: 7 } });
    expect(hiddenInline(view)).toEqual(['`', '`']);
    expect(view.contentDOM.querySelector('.cm-inkpot-heading1')).toBeNull();
    expect(view.contentDOM.querySelector('.cm-inkpot-list-marker')).toBeNull();
    expect(view.contentDOM.querySelector('script')).toBeNull();
    expect(read()).toBe(original);
  });

  test('切换保留字节、正反选区及撤销历史，快捷键与命令共用状态', () => {
    const original = '\uFEFF# 中文\r\n**e\u0301**\r尾\n';
    const { view, read } = editor(original);
    view.dispatch({ selection: EditorSelection.single(11, 8) });
    formatCommands.italic?.(view);
    const formatted = read();
    const selection = view.state.selection;
    expect(undoDepth(view.state)).toBe(1);
    toggleSourceMode(view);
    expect(view.dom.classList.contains('cm-inkpot-source')).toBe(true);
    expect(view.contentDOM.querySelector('.cm-inkpot-hidden-inline')).toBeNull();
    expect(view.state.selection.eq(selection)).toBe(true);
    expect(undoDepth(view.state)).toBe(1);
    expect(read()).toBe(formatted);
    view.focus();
    const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform);
    view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'M', keyCode: 77, shiftKey: true, metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true,
    }));
    expect(view.state.field(sourceMode)).toBe(false);
    expect(view.state.selection.eq(selection)).toBe(true);
    undo(view);
    expect(read()).toBe(original);
    redo(view);
    expect(read()).toBe(formatted);
  });

  test.each(['# 内容', '- 内容', '> 内容'])('键盘越过隐藏块标记，退格去掉标记可撤销：%s', text => {
    const { view, read } = editor(text);
    cursorCharRight(view);
    expect(view.state.selection.main.head).toBe(2);
    cursorCharLeft(view);
    expect(view.state.selection.main.head).toBe(0);
    cursorCharRight(view);
    deleteCharBackward(view);
    expect(read()).toBe('内容');
    undo(view);
    expect(read()).toBe(text);
  });

  test('搜索隐藏标记时只显示当前匹配，关闭后恢复预览且不改文档模式', () => {
    const original = '# 标题\n- 列表\n**粗体**';
    const { view, read } = editor(original);
    searchCommands.find(view);
    for (const query of ['#', '-', '**']) {
      view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: query, literal: true })) });
      searchCommands.findNext(view);
      const matched = view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to);
      expect(matched).toBe(query);
      const lines = Array.from(view.contentDOM.querySelectorAll('.cm-line'), line => line.textContent);
      expect(lines.some(line => line.includes(query))).toBe(true);
      if (query === '**') expect(hiddenInline(view)).toEqual([]);
    }
    expect(view.state.field(sourceMode)).toBe(false);
    view.dom.querySelector<HTMLButtonElement>('button[name=close]')?.click();
    view.dispatch({ selection: { anchor: 0 } });
    expect(hiddenInline(view)).toEqual(['**', '**']);
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '#', literal: true })) });
    searchCommands.findNext(view);
    expect(view.dom.querySelector('[role=search]')).toBeNull();
    expect(view.contentDOM.querySelector('.cm-inkpot-heading1')?.textContent).toBe('# 标题');
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('组合输入期间不重建装饰，结束后恢复局部展开，阻止中途切换模式', async () => {
    const { view, read } = editor('**中文** 后', 3);
    view.focus();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    expect(view.compositionStarted).toBe(true);
    view.dispatch({ selection: { anchor: 8 } });
    expect(hiddenInline(view)).toEqual([]);
    expect(toggleSourceMode(view)).toBe(false);
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 100));
    expect(hiddenInline(view)).toEqual(['**', '**']);
    expect(read()).toBe('**中文** 后');
  });
});
