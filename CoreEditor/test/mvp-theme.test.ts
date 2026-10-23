import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing } from '../mvp/live';
import { applyAppearance, appearanceExtensionsFor } from '../mvp/theme';
import { useKatexForTests } from '../mvp/math';

// 公式 widget 渲染是异步的，测试注入假 KaTeX 避免从应用包加载。
useKatexForTests({
  render(_tex, element) {
    element.textContent = '公式';
    element.classList.add('fake-katex');
  },
});

const views: EditorView[] = [];
afterEach(() => {
  for (const view of views.splice(0)) view.destroy();
  document.documentElement.classList.remove('inkpot-dark');
});
function editor(text: string) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, ...appearanceExtensionsFor(false), history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
async function flushed() {
  await new Promise(resolve => setTimeout(resolve, 0));
}

const original = '# 标题\r\n\r\n正文 `code` 与 $x^2$ 公式\r\n\r\n```js\r\nconst a = 1;\r\n```\r\n\r\n| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\n> 引用';

describe('MVP 外观', () => {
  test('初始为浅色：编辑器无 cm-mvp-dark，页面根无 inkpot-dark，dark 主题未激活', () => {
    const { view } = editor(original);
    expect(view.dom.classList.contains('cm-mvp-dark')).toBe(false);
    expect(view.dom.classList.contains('cm-mvp-live')).toBe(true);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(false);
    expect(view.state.facet(EditorView.darkTheme)).toBe(false);
  });

  test('applyAppearance(true) 给编辑器根挂 cm-mvp-dark、页面根挂 inkpot-dark，dark 作用域激活', () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    expect(view.dom.classList.contains('cm-mvp-dark')).toBe(true);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(true);
    expect(view.state.facet(EditorView.darkTheme)).toBe(true);
    // 与预览模式的类共存，不被外观切换覆盖。
    expect(view.dom.classList.contains('cm-mvp-live')).toBe(true);
  });

  test('切回浅色后编辑器与页面根的深色类都移除，dark 作用域关闭', () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    applyAppearance(view, false);
    expect(view.dom.classList.contains('cm-mvp-dark')).toBe(false);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(false);
    expect(view.state.facet(EditorView.darkTheme)).toBe(false);
  });

  test('外观切换不修改源文档字节，也不产生可撤销的历史', () => {
    const { view, read } = editor(original);
    applyAppearance(view, true);
    applyAppearance(view, false);
    applyAppearance(view, true);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('深色下表格、代码块、行内代码、行内公式与引用照常渲染', async () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    await flushed();
    expect(view.dom.querySelector('.cm-mvp-table table')).not.toBeNull();
    expect(view.dom.querySelectorAll('.cm-mvp-table th')).toHaveLength(2);
    expect(view.dom.querySelector('.cm-mvp-code')).not.toBeNull();
    expect(view.dom.querySelector('.cm-mvp-code-language')?.textContent).toBe('js');
    expect(view.dom.querySelector('.cm-mvp-inline-code')).not.toBeNull();
    expect(view.dom.querySelector('.cm-mvp-math.fake-katex')).not.toBeNull();
    expect(view.dom.querySelector('.cm-mvp-quote')).not.toBeNull();
  });

  test('浅色切深色再切回，已渲染的 widget 仍在且文档可继续编辑撤销', async () => {
    const { view, read } = editor(original);
    await flushed();
    applyAppearance(view, true);
    applyAppearance(view, false);
    expect(view.dom.querySelector('.cm-mvp-table table')).not.toBeNull();
    expect(view.dom.querySelector('.cm-mvp-math.fake-katex')).not.toBeNull();
    view.dispatch({ changes: { from: 0, insert: '新增' } });
    expect(read().startsWith('新增# 标题')).toBe(true);
    expect(undoDepth(view.state)).toBe(1);
  });
});
