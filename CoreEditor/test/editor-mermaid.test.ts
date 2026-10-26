import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undo, undoDepth } from '@codemirror/commands';
import { SearchQuery, findNext, setSearchQuery } from '@codemirror/search';
import { MermaidConfig } from 'mermaid';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { useMermaidForTests } from '../editor/mermaid';
import { applyAppearance, appearanceExtensionsFor } from '../editor/theme';
import { documentHTML } from '../editor/export';

const views: EditorView[] = [];
const renders: string[] = [];
const configurations: MermaidConfig[] = [];
let finish: (() => void) | undefined;
useMermaidForTests({
  initialize(config) { configurations.push(config); },
  async render(id, text) {
    renders.push(text);
    if (text.includes('broken')) throw new Error('语法错误');
    if (text.includes('delayed')) await new Promise<void>(resolve => { finish = resolve; });
    return { svg: `<svg id="${id}"><text>${text.includes('changed') ? '新图' : '图形'}</text></svg>`, diagramType: 'flowchart' };
  },
});
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });
function editor(text: string, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, ...appearanceExtensionsFor(false), history(), EditorState.readOnly.of(readOnly)],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
const flushed = () => new Promise(resolve => setTimeout(resolve, 0));
const original = '前文\r\n\r\n```mermaid\r\nflowchart LR\n甲 --> 乙\r\n```\r\n\r\n尾';

describe('Inkpot Mermaid', () => {
  test.each([original, '```mermaid\r\nflowchart LR\n甲 --> 乙\r\n```'])('源码按钮原地恢复图表，保留原文和撤销历史：%s', async text => {
    const { view, read } = editor(text);
    await flushed();
    for (let cycle = 0; cycle < 2; cycle++) {
      view.dom.querySelector('.cm-inkpot-mermaid')?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
      const button = view.dom.querySelector<HTMLButtonElement>('.cm-inkpot-mermaid-show');
      expect(button?.textContent).toBe('显示 Mermaid 图');
      expect(view.dom.querySelector('.cm-inkpot-code-language')?.textContent).toBe('mermaid');
      button?.click();
      await flushed();
      expect(view.dom.querySelector('.cm-inkpot-mermaid svg')).not.toBeNull();
      expect(view.dom.querySelector('.cm-inkpot-mermaid-show')).toBeNull();
      expect(read()).toBe(text);
      expect(undoDepth(view.state)).toBe(0);
    }
  });

  test('源码按钮避开全局源码模式、只读和组合输入', async () => {
    const { view, read } = editor(original);
    view.dispatch({ selection: { anchor: view.state.doc.toString().indexOf('甲') } });
    const button = view.dom.querySelector<HTMLButtonElement>('.cm-inkpot-mermaid-show');
    expect(button).not.toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    button?.click();
    expect(view.dom.querySelector('.cm-inkpot-mermaid')).toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    toggleSourceMode(view);
    expect(view.dom.querySelector('.cm-inkpot-mermaid-show')).toBeNull();
    const readonly = editor(original, true);
    readonly.view.dispatch({ selection: { anchor: readonly.view.state.doc.toString().indexOf('甲') } });
    expect(readonly.view.dom.querySelector('.cm-inkpot-mermaid-show')).toBeNull();
    expect(read()).toBe(original);
  });

  test('离线图表装饰保持原文，点击展开、修改后移出更新，撤销恢复字节', async () => {
    const { view, read } = editor(original);
    await flushed();
    expect(view.dom.querySelector('.cm-inkpot-mermaid svg')).not.toBeNull();
    expect(undoDepth(view.state)).toBe(0);
    const widget = view.dom.querySelector<HTMLElement>('.cm-inkpot-mermaid');
    widget?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.dom.querySelector('.cm-inkpot-mermaid')).toBeNull();
    const position = view.state.doc.toString().indexOf('甲');
    view.dispatch({ changes: { from: position, to: position + 1, insert: 'changed' }, userEvent: 'input.type' });
    view.dispatch({ selection: { anchor: 0 } });
    await flushed();
    expect(view.dom.querySelector('svg text')?.textContent).toBe('新图');
    undo(view);
    expect(read()).toBe(original);
  });

  test('模式、主题与查找切换只更新预览，不改文档；普通光标移动不重复渲染', async () => {
    const { view, read } = editor(original);
    await flushed();
    const count = renders.length;
    view.dispatch({ selection: { anchor: 1 } });
    await flushed();
    expect(renders).toHaveLength(count);
    applyAppearance(view, true);
    await flushed();
    expect(configurations.at(-1)?.theme).toBe('dark');
    expect(configurations.at(-1)?.securityLevel).toBe('strict');
    expect(configurations.at(-1)?.secure).toContain('maxEdges');
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '甲' })) });
    findNext(view);
    expect(view.dom.querySelector('.cm-inkpot-mermaid')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    toggleSourceMode(view);
    expect(view.dom.querySelector('.cm-inkpot-mermaid')).toBeNull();
    toggleSourceMode(view);
    await flushed();
    expect(view.dom.querySelector('svg')).not.toBeNull();
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('普通代码、未闭合、空图表与嵌套容器保持源码', async () => {
    const text = '```js\nflowchart LR\n```\n\n> ```mermaid\n> graph TD\n> A-->B\n> ```\n\n```mermaid\n\n```\n\n```mermaid\nA-->B';
    const { view, read } = editor(text);
    await flushed();
    expect(view.dom.querySelector('.cm-inkpot-mermaid')).toBeNull();
    expect(read()).toBe(text);
  });

  test('语法失败与过大图表显示可编辑源码，后续图表继续渲染', async () => {
    const { view, read } = editor('前\n\n```mermaid\nbroken\n```\n\n```mermaid\ngraph TD\nA-->B\n```');
    await flushed();
    expect(view.dom.querySelector('.cm-inkpot-mermaid-error')?.textContent).toContain('broken');
    expect(view.dom.querySelector('svg')).not.toBeNull();
    expect(read()).toContain('broken');
    const count = renders.length;
    const text = '前\n\n```mermaid\n' + 'x'.repeat(50001) + '\n```';
    const huge = editor(text);
    await flushed();
    expect(renders).toHaveLength(count);
    expect(huge.read()).toBe(text);
    expect(configurations.at(-1)?.maxTextSize).toBe(50000);
  });

  test('迟到结果不覆盖新内容；只读与组合输入期间点击不展开', async () => {
    const { view } = editor('前\n\n```mermaid\ndelayed\n```');
    await flushed();
    const old = view.dom.querySelector('.cm-inkpot-mermaid');
    const from = view.state.doc.toString().indexOf('delayed');
    view.dispatch({ changes: { from, to: from + 'delayed'.length, insert: 'changed' } });
    finish?.();
    await flushed();
    expect(old?.isConnected).toBe(false);
    expect(view.dom.querySelector('svg text')?.textContent).toBe('新图');
    const readonly = editor(original, true);
    await flushed();
    readonly.view.dom.querySelector('.cm-inkpot-mermaid')?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(readonly.view.dom.querySelector('svg')).not.toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    view.dom.querySelector('.cm-inkpot-mermaid')?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    expect(view.dom.querySelector('svg')).not.toBeNull();
  });

  test('源码模式和图表内选区导出均等待 SVG，恢复原文、选区和外观', async () => {
    const { view, read } = editor(original);
    const anchor = view.state.doc.toString().indexOf('甲');
    view.dispatch({ selection: { anchor } });
    applyAppearance(view, true);
    toggleSourceMode(view);
    for (const mode of ['html', 'pdf'] as const) {
      const html = await documentHTML(view, mode);
      expect(html).toContain('<svg');
      expect(html).not.toContain('data-render-pending');
      expect(view.dom.matches('.cm-inkpot-source')).toBe(true);
      expect(view.state.facet(EditorView.darkTheme)).toBe(true);
      expect(view.state.selection.main.head).toBe(anchor);
    }
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('等待图表期间发生编辑时取消导出，保留新输入和选区', async () => {
    const { view, read } = editor('前\n\n```mermaid\ndelayed\n```');
    const exporting = expect(documentHTML(view)).rejects.toThrow('导出期间发生编辑');
    await flushed();
    view.dispatch({ changes: { from: 0, insert: '新' }, selection: { anchor: 1 } });
    finish?.();
    await exporting;
    expect(read().startsWith('新前')).toBe(true);
    expect(view.state.selection.main.head).toBe(1);
  });
});
