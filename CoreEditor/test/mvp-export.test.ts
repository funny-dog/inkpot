import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';
import { documentHTML } from '../mvp/export';
import { useKatexForTests } from '../mvp/math';

useKatexForTests({
  render(tex, element) {
    element.innerHTML = '<span class="katex"><span class="katex-mathml"><math>mathml-' + tex + '</math></span><span class="katex-html">html-' + tex + '</span></span>';
  },
});

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

const original = '# 标题\r\n\r\n**加粗** ~~删除~~ ==高亮== `代码`\r\n\r\n| a | b |\n| --- | --- |\n| 1 | 2 |\r\n\r\n$$\nE = mc^2\n$$\r\n\r\n- [x] 任务\n\n[link](https://example.com)\r\n\r\n尾行';

function parse(html: string) {
  const doc = document.implementation.createHTMLDocument();
  doc.body.innerHTML = html;
  return doc;
}

async function flushed() {
  await new Promise(resolve => setTimeout(resolve, 0));
}

describe('MVP 导出', () => {
  test('PDF 模式输出完整结构：标题、行内样式、表格与公式排版副本', async () => {
    const { view } = editor(original);
    await flushed();
    const html = await documentHTML(view, 'pdf');
    const doc = parse(html.slice(html.indexOf('<body>') + 6, html.lastIndexOf('</body>')));
    expect(html).toContain('<!doctype html>');
    expect(html).toContain('inkpot-asset://math/katex.min.css');
    expect(doc.querySelector('.cm-mvp-table table')).not.toBeNull();
    expect(doc.querySelector('.katex-html')).not.toBeNull();
    expect(doc.querySelector('math')?.textContent).toContain('mathml-E = mc^2');
    // 行内语法样式被内联：加粗与高亮（jsdom 不计算 text-decoration，删除线在原生测试中验证）。
    expect(html).toContain('font-weight: bold');
    expect(html).toContain('rgba(255, 212, 0, 0.4)');
  });

  test('HTML 模式去除编辑器痕迹，公式保留 MathML、去掉排版副本', async () => {
    const { view } = editor(original);
    await flushed();
    const html = await documentHTML(view, 'html');
    const doc = parse(html.slice(html.indexOf('<body>') + 6, html.lastIndexOf('</body>')));
    expect(html).not.toContain('inkpot-asset://math/katex.min.css');
    expect(doc.querySelector('.cm-mvp-table-input')).toBeNull();
    expect(doc.querySelector('.cm-mvp-table-hint')).toBeNull();
    expect(doc.querySelector('.cm-mvp-hidden-inline')).toBeNull();
    expect(doc.querySelector('[contenteditable]')).toBeNull();
    expect(doc.querySelector('.katex-html')).toBeNull();
    expect(doc.querySelector('math')?.getAttribute('aria-hidden')).toBeNull();
    // 表格的隐藏输入框删除后，预览单元格文本仍在。
    const cell = doc.querySelector('td');
    expect(cell?.textContent).toContain('1');
    // 任务勾选框保留选中状态且不可交互。
    const box = doc.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
    expect(box?.checked).toBe(true);
    expect(box?.disabled).toBe(true);
  });

  test('源码模式与光标位置的临时状态被恢复，源文档不变', async () => {
    const { view, read } = editor(original);
    toggleSourceMode(view);
    view.dispatch({ selection: { anchor: original.replace(/\r\n/g, '\n').indexOf('加粗') } });
    const html = await documentHTML(view, 'html');
    expect(html).toContain('加粗');
    // 导出以实时视图为准，结束后源码模式与光标恢复原状。
    expect(view.dom.matches('.cm-mvp-source')).toBe(true);
    expect(view.state.selection.main.head).toBe(original.replace(/\r\n/g, '\n').indexOf('加粗'));
    toggleSourceMode(view);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('导出标题取首行，空文档有占位', async () => {
    const { view } = editor('# 首行标题\n\n正文');
    expect(await documentHTML(view, 'html')).toContain('<title>首行标题</title>');
    const empty = editor('正文没有标题');
    expect(await documentHTML(empty.view, 'html')).toContain('<title>正文没有标题</title>');
  });

  test('代码着色在首次导出时加载语言并内联为颜色', async () => {
    const { view } = editor('```swift\nlet 名称 = "值" // 注释\n```');
    const html = await documentHTML(view, 'html');
    const doc = parse(html.slice(html.indexOf('<body>') + 6, html.lastIndexOf('</body>')));
    const keyword = doc.querySelector<HTMLElement>('.cm-mvp-token-keyword');
    expect(keyword?.textContent).toBe('let');
    expect(keyword?.style.color).toBe('rgb(166, 38, 164)');
    expect(doc.querySelector<HTMLElement>('.cm-mvp-token-string')?.style.color).toBe('rgb(80, 161, 79)');
    expect(doc.querySelector<HTMLElement>('.cm-mvp-token-comment')?.style.fontStyle).toBe('italic');
  });
});
