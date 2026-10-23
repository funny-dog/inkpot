import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undo, undoDepth } from '@codemirror/commands';
import { findNext, SearchQuery, setSearchQuery } from '@codemirror/search';
import { syntaxTree } from '@codemirror/language';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';
import { footnoteDefTagName, inlineHighlightTagName } from '../mvp/gfm';

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

function hasNode(view: EditorView, name: string) {
  let found = false;
  syntaxTree(view.state).iterate({ enter(node) { if (node.name === name) found = true; } });
  return found;
}

const original = '前文\r\n\r\n- [ ] 未完成任务\n- [x] 已完成\r\n\r\n删除 ~~旧内容~~ 与高亮 ==新内容==\r\n\r\n引用脚注[^note1]。\r\n\r\n[^note1]: 脚注定义内容\r\n\r\n尾行';
const plain = original.replace(/\r\n/g, '\n');

describe('MVP GFM 语法', () => {
  test('任务列表渲染勾选框，点击切换且撤销精确恢复', () => {
    const { view, read } = editor(original);
    const boxes = view.dom.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
    expect(boxes).toHaveLength(2);
    expect(boxes[0].checked).toBe(false);
    expect(boxes[1].checked).toBe(true);
    boxes[0].click();
    expect(read()).toBe(original.replace('- [ ] 未完成任务', '- [x] 未完成任务'));
    expect((view.dom.querySelectorAll('input[type="checkbox"]')[0] as HTMLInputElement).checked).toBe(true);
    undo(view);
    expect(read()).toBe(original);
    expect((view.dom.querySelectorAll('input[type="checkbox"]')[0] as HTMLInputElement).checked).toBe(false);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('删除线与高亮渲染，光标进入局部展开标记，源码模式显示原文', () => {
    const { view, read } = editor(original);
    expect(hasNode(view, 'Strikethrough')).toBe(true);
    expect(hasNode(view, inlineHighlightTagName)).toBe(true);
    expect(view.dom.textContent).toContain('旧内容');
    expect(view.dom.textContent).toContain('新内容');
    // 全文档共四对标记（删除线两段、高亮两段）被隐藏。
    expect(view.dom.querySelectorAll('.cm-mvp-hidden-inline')).toHaveLength(4);
    // 光标进入删除线内容时展开其 ~~ 标记，高亮标记不受影响。
    view.dispatch({ selection: { anchor: plain.indexOf('旧内容') } });
    expect(view.dom.querySelectorAll('.cm-mvp-hidden-inline')).toHaveLength(2);
    view.dispatch({ selection: { anchor: plain.indexOf('新内容') } });
    expect(view.dom.querySelectorAll('.cm-mvp-hidden-inline')).toHaveLength(2);
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelectorAll('.cm-mvp-hidden-inline')).toHaveLength(4);
    toggleSourceMode(view);
    expect(view.dom.querySelectorAll('input[type="checkbox"]')).toHaveLength(0);
    toggleSourceMode(view);
    expect(view.dom.querySelectorAll('input[type="checkbox"]')).toHaveLength(2);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('高亮边界：未闭合、空内容与跨行保持原样', () => {
    const text = '未闭合 ==内容\n空 ==== 与 ==a==\n跨行 ==\n内容== 结束';
    const { view, read } = editor(text);
    expect(hasNode(view, inlineHighlightTagName)).toBe(true);
    expect(view.dom.textContent).toContain('==');
    expect(read()).toBe(text);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('脚注引用渲染为上标并带定义提示，定义行保留源码', () => {
    const { view, read } = editor(original);
    const ref = view.dom.querySelector('.cm-mvp-footnote-ref') as HTMLElement | null;
    expect(ref).not.toBeNull();
    expect(ref?.textContent).toBe('note1');
    expect(ref?.title).toBe('脚注定义内容');
    expect(hasNode(view, footnoteDefTagName)).toBe(true);
    expect(view.dom.textContent).toContain('[^note1]: 脚注定义内容');
    // 光标进入引用时展开源码。
    ref?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.dom.querySelector('.cm-mvp-footnote-ref')).toBeNull();
    expect(view.state.selection.main.head).toBe(plain.indexOf('[^note1]') + 1);
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('.cm-mvp-footnote-ref')).not.toBeNull();
    // 孤立引用与定义标记本身不渲染为引用。
    const orphan = editor('孤立[^缺失]与[^空]\n[^缺失]: 另一个定义');
    expect(orphan.view.dom.querySelector('.cm-mvp-footnote-ref')?.textContent).toBe('缺失');
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('目录 [toc] 渲染标题列表并点击跳转，无标题时显示占位', () => {
    const doc = '# 一级\n\n[toc]\n\n## 二级\n\n正文\n';
    const { view, read } = editor(doc);
    const toc = view.dom.querySelector('.cm-mvp-toc');
    expect(toc).not.toBeNull();
    const items = view.dom.querySelectorAll('.cm-mvp-toc-item');
    expect(items).toHaveLength(2);
    expect(items[0].textContent).toBe('一级');
    expect((items[1] as HTMLElement).style.paddingLeft).toBe('18px');
    items[1].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.state.selection.main.head).toBe(doc.indexOf('## 二级'));
    view.dispatch({ selection: { anchor: doc.indexOf('[toc]') + 1 } });
    expect(view.dom.querySelector('.cm-mvp-toc')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('.cm-mvp-toc')).not.toBeNull();
    const empty = editor('[TOC]\n\n正文');
    expect(empty.view.dom.querySelector('.cm-mvp-toc-empty')?.textContent).toBe('暂无标题');
    expect(read()).toBe(doc);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('搜索任务标记与目录标记时展开源码', () => {
    const doc = '- [ ] 任务\n\n[toc]\n\n## 标题\n';
    const { view } = editor(doc);
    expect(view.dom.querySelector('input[type="checkbox"]')).not.toBeNull();
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '[ ]' })) });
    findNext(view);
    expect(view.dom.querySelector('input[type="checkbox"]')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('input[type="checkbox"]')).not.toBeNull();
  });

  test('嵌套容器与只读约束', () => {
    const nested = '> - [ ] 引用中的任务\n> [toc]\n';
    const { view } = editor(nested);
    expect(view.dom.querySelector('input[type="checkbox"]')).not.toBeNull();
    expect(view.dom.querySelector('.cm-mvp-toc')).toBeNull();
    const readonly = editor(original, true);
    const boxes = readonly.view.dom.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
    expect(boxes).toHaveLength(2);
    expect(boxes[0].disabled).toBe(true);
    boxes[0].click();
    expect(readonly.read()).toBe(original);
    expect(readonly.view.dom.querySelector('.cm-mvp-footnote-ref')).not.toBeNull();
  });

  test('组合输入期间不重建 GFM 装饰', () => {
    const { view } = editor('正文\n');
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    view.dispatch({ changes: { from: 3, insert: '- [ ] 任务' } });
    expect(view.dom.querySelector('input[type="checkbox"]')).toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    expect(view.dom.querySelector('input[type="checkbox"]')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.dom.querySelector('input[type="checkbox"]')).not.toBeNull();
  });
});
