import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { undoDepth, history } from '@codemirror/commands';
import { getSearchQuery, SearchQuery, setSearchQuery, findNext } from '@codemirror/search';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { linkAt } from '../editor/basic';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });
function editor(text: string) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
const hidden = (view: EditorView) => [...view.contentDOM.querySelectorAll('.cm-inkpot-hidden-inline')].map(node => node.textContent);

describe('Inkpot 常用 Markdown 补齐', () => {
  test('行内代码局部展开，代码内容不解析为强调或链接，原文与历史不变', () => {
    const original = '前 `a **b** [c](x)` 和 ``x ` y`` 尾\r\n';
    const { view, read } = editor(original);
    expect(view.contentDOM.querySelectorAll('.cm-inkpot-inline-code')).toHaveLength(2);
    expect(view.contentDOM.querySelector('.cm-inkpot-link')).toBeNull();
    expect(hidden(view)).toEqual(['`', '`', '``', '``']);
    view.dispatch({ selection: { anchor: 4 } });
    expect(hidden(view)).toEqual(['``', '``']);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('链接只隐藏标记和目标，嵌套强调与光标展开相互配合', () => {
    const { view } = editor('前 [**文字**](https://example.com "说明") 后');
    expect(view.contentDOM.querySelector('.cm-inkpot-link')).not.toBeNull();
    expect(hidden(view)).toContain('](https://example.com "说明")');
    view.dispatch({ selection: { anchor: 7 } });
    expect(hidden(view)).toEqual([]);
    expect(linkAt(view, 7)).toBe('https://example.com');
    view.dispatch({ selection: EditorSelection.single(12, 3) });
    expect(hidden(view)).toEqual([]);
  });

  test('识别行内、尖括号、邮件和三种引用式链接，解码实体与反斜杠', () => {
    const { view } = editor('前 [内联](<a%20b.md>) <https://example.com> <a@example.com> [引用][ID] [简称][] [shortcut]\n\n[id]: /doc.md?a=1&amp;b=2\n[简称]: ./short.md\n[shortcut]: ./last.md');
    const text = view.state.doc.toString();
    for (const [word, destination] of [
      ['内联', 'a%20b.md'], ['https://', 'https://example.com'], ['a@example', 'mailto:a@example.com'],
      ['引用', '/doc.md?a=1&b=2'], ['简称', './short.md'], ['shortcut', './last.md'],
    ]) expect(linkAt(view, text.indexOf(word) + 1)).toBe(destination);
  });

  test('下划线式单行、多行和引用标题具有对应级别，列表与分隔线不误判', () => {
    const original = '一级\r\n===\n\n二级\n---\n\n多行\n标题\n===\n\n> 引用\n> ---\n\n- 列表\n\n---';
    const { view, read } = editor(original);
    expect(view.contentDOM.querySelectorAll('.cm-inkpot-heading1')).toHaveLength(3);
    expect(view.contentDOM.querySelectorAll('.cm-inkpot-heading2')).toHaveLength(2);
    expect(view.contentDOM.querySelectorAll('.cm-inkpot-setext-mark')).toHaveLength(4);
    expect(view.contentDOM.querySelectorAll('[role=separator]')).toHaveLength(1);
    expect(read()).toBe(original);
  });

  test('分隔线显示为分隔元素，源码切换保留精确字节和选区', () => {
    const original = '前\r\n\r\n***\n\n_ _ _\r\n\r\n---\n';
    const { view, read } = editor(original);
    expect(view.contentDOM.querySelectorAll('[role=separator]')).toHaveLength(3);
    view.dispatch({ selection: EditorSelection.single(1, 0) });
    toggleSourceMode(view);
    expect(view.contentDOM.querySelector('[role=separator]')).toBeNull();
    expect(view.state.selection.main.anchor).toBe(1);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('搜索到分隔线与标题下划线时显示源码，关闭搜索后的导航仍可命中', () => {
    const { view, read } = editor('标题\n---\n\n---');
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '---' })) });
    findNext(view);
    expect(getSearchQuery(view.state).search).toBe('---');
    expect(view.contentDOM.querySelectorAll('.cm-inkpot-setext-mark')).toHaveLength(0);
    findNext(view);
    expect(view.contentDOM.querySelectorAll('[role=separator]')).toHaveLength(0);
    expect(read()).toBe('标题\n---\n\n---');
  });

  test('代码块与原始 HTML 中的伪链接和分隔符保持字面文本', () => {
    const { view } = editor('```\n[x](https://example.com)\n---\n```\n\n<div>\n[a](javascript:alert(1))\n---\n</div>');
    expect(view.contentDOM.querySelector('.cm-inkpot-link')).toBeNull();
    expect(view.contentDOM.querySelector('[role=separator]')).toBeNull();
    expect(linkAt(view, 8)).toBeUndefined();
    expect(view.contentDOM.querySelector('script')).toBeNull();
  });
});
