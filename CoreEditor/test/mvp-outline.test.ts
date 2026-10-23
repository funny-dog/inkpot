import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { commonmarkLanguage } from '@codemirror/lang-markdown';
import { history, undo, undoDepth } from '@codemirror/commands';
import { activeHeading, documentOutline, headings } from '../mvp/outline';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string) {
  const source = sourceDocument(text);
  const published: unknown[] = [];
  const outline = documentOutline((items, active) => published.push({ items, active }));
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history(), outline.extension],
  }) });
  views.push(view);
  const plugin = view.plugin(outline.extension);
  if (plugin === null) throw new Error('缺少大纲插件');
  plugin.refresh();
  return { view, outline, plugin, published, read: () => source.read(view.state) };
}

function parse(text: string) {
  return headings(EditorState.create({ doc: text }), commonmarkLanguage.parser.parse(text));
}

describe('MVP 标题大纲', () => {
  test('识别六级 ATX 和两级 Setext，保留跳级与重复标题顺序', () => {
    const items = parse('# 一\n### 三\n## 二\n#### 四\n##### 五\n###### 六\n\n一\n===\n\n二\n---\n\n# 一');
    expect(items.map(item => [item.level, item.title])).toEqual([
      [1, '一'], [3, '三'], [2, '二'], [4, '四'], [5, '五'], [6, '六'], [1, '一'], [2, '二'], [1, '一'],
    ]);
  });

  test('剔除标题行内标记、闭合井号和链接目标，不执行 HTML', () => {
    expect(parse('# **粗体** 与 *斜体* [链接](https://example.com "说明") `code` ![图](a.png) ##')[0].title)
      .toBe('粗体 与 斜体 链接 code 图');
    expect(parse('# <script>alert(1)</script>')[0].title).toBe('<script>alert(1)</script>');
    expect(parse('#')[0].title).toBe('（空标题）');
  });

  test('排除围栏、缩进代码、HTML 块和无效井号，包含引用中的真实标题', () => {
    const items = parse('```md\n# 假\n```\n\n    # 假\n\n<div>\n# 假\n</div>\n\n#无空格\n####### 七\n\n> ## 引用\n\n- ### 列表标题');
    expect(items.map(item => item.title)).toEqual(['引用', '列表标题']);
  });

  test('导航进入标题内容，源码切换和滚动定位不改原文或历史', () => {
    const original = '# 中文\r\n正文\n\n## **重复**\r\n尾\n\n## **重复**';
    const { view, outline, plugin, read } = editor(original);
    const target = plugin.items[2];
    outline.navigate(view, target.id);
    expect(view.state.selection.main.head).toBe(target.from + 3);
    expect(view.hasFocus).toBe(true);
    toggleSourceMode(view);
    outline.navigate(view, plugin.items[0].id);
    expect(view.state.selection.main.head).toBe(2);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('重命名、前文增行、重复标题及撤销保持已有标题身份', () => {
    const { view, plugin } = editor('# 同名\n\n## 同名\n\n# 同名');
    const ids = plugin.items.map(item => item.id);
    view.dispatch({ changes: { from: 2, to: 4, insert: '重命名' } });
    plugin.refresh();
    expect(plugin.items.map(item => item.id)).toEqual(ids);
    expect(plugin.items[0].title).toBe('重命名');
    view.dispatch({ changes: { from: 0, insert: '前文\n\n# 新标题\n\n' } });
    plugin.refresh();
    expect(plugin.items.slice(1).map(item => item.id)).toEqual(ids);
    expect(new Set(plugin.items.map(item => item.id)).size).toBe(4);
    undo(view);
    plugin.refresh();
    expect(plugin.items.map(item => item.id)).toEqual(ids);
  });

  test('导航已删除标题安全忽略，空文档大纲为空', () => {
    const { view, outline, plugin } = editor('# 删除\n\n# 保留');
    const removed = plugin.items[0].id;
    view.dispatch({ changes: { from: 0, to: 6 } });
    outline.navigate(view, removed);
    expect(plugin.items.map(item => item.title)).toEqual(['保留']);
    expect(plugin.items.some(item => item.id === removed)).toBe(false);
    view.dispatch({ changes: { from: 0, to: view.state.doc.length } });
    plugin.refresh();
    expect(plugin.items).toEqual([]);
  });

  test('当前章节按视口位置决定，首标题之前为空，重复标题分别定位', () => {
    const { plugin } = editor('前言\n\n# 同名\n正文\n\n## 同名\n尾');
    expect(activeHeading(plugin.items, 0)).toBeNull();
    expect(activeHeading(plugin.items, plugin.items[0].from)).toBe(plugin.items[0].id);
    expect(activeHeading(plugin.items, plugin.items[1].from - 1)).toBe(plugin.items[0].id);
    expect(activeHeading(plugin.items, 999)).toBe(plugin.items[1].id);
  });

  test('组合输入期间延迟更新和导航，结束后补齐正文视口之外的标题', () => {
    const { view, outline, plugin } = editor('# 开头\n\n' + '正文\n\n'.repeat(300) + '# 末尾');
    expect(plugin.items.map(item => item.title)).toEqual(['开头', '末尾']);
    Object.defineProperty(view, 'composing', { configurable: true, value: true });
    view.dispatch({ changes: { from: 2, to: 4, insert: '改名' } });
    const before = view.state.selection.main.head;
    expect(plugin.refresh()).toBe(false);
    outline.navigate(view, plugin.items[1].id);
    expect(view.state.selection.main.head).toBe(before);
    Object.defineProperty(view, 'composing', { configurable: true, value: false });
    expect(plugin.refresh()).toBe(true);
    expect(plugin.items[0].title).toBe('改名');
  });
});
