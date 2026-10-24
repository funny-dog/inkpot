import { afterEach, describe, expect, jest, test } from '@jest/globals';
import TurndownService from 'turndown';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, sourceMode, toggleSourceMode } from '../editor/live';
import { htmlToMarkdown, richPaste } from '../editor/paste';

const views: EditorView[] = [];
function editor(text: string, position?: number, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({
      doc: source.doc,
      selection: EditorSelection.cursor(position ?? source.doc.length),
      extensions: [...source.extensions, ...writingExtensions, ...liveEditing, richPaste,
        history(), keymap.of(defaultKeymap), EditorState.readOnly.of(readOnly)],
    }),
  });
  views.push(view);
  view.focus();
  return { view, read: () => source.read(view.state) };
}
afterEach(() => {
  for (const view of views.splice(0)) view.destroy();
  jest.restoreAllMocks();
});

function pasteEvent(html: string, files: File[] = [], plain = '') {
  const clipboardData = {
    files,
    getData: (type: string) => (type.toLowerCase() === 'text/html' ? html : plain),
  };
  // jsdom 没有 ClipboardEvent 构造器，CodeMirror 只按事件名监听，普通 Event 即可。
  const event = new Event('paste', { bubbles: true, cancelable: true });
  Object.defineProperty(event, 'clipboardData', { value: clipboardData });
  return event;
}

describe('Inkpot 富文本粘贴', () => {
  test('行内富文本转换为对应 Markdown 语法', () => {
    expect(htmlToMarkdown('<p><strong>粗体</strong>、<em>斜体</em>、<code>x=1</code>、<a href="https://a.dev">链接</a></p>'))
      .toBe('**粗体**、*斜体*、`x=1`、[链接](https://a.dev)');
  });

  test('标题、列表与代码块按编辑器约定的风格转换', () => {
    const markdown = htmlToMarkdown('<h2>标题</h2><ul><li>甲</li><li>乙</li></ul><pre><code class="language-js">let a = 1;</code></pre>');
    expect(markdown).toContain('## 标题');
    expect(markdown).toContain('- 甲\n- 乙');
    expect(markdown).toContain('```js\nlet a = 1;\n```');
  });

  test('HTML 表格转换为 Markdown 表格并转义竖线', () => {
    const markdown = htmlToMarkdown('<table><tr><th>名</th><th>a|b</th></tr><tr><td>x</td><td>1</td></tr></table>');
    expect(markdown).toContain('| 名 | a\\|b |');
    expect(markdown).toContain('| --- | --- |');
    expect(markdown).toContain('| x | 1 |');
  });

  test('图片保留，脚本等内容移除', () => {
    expect(htmlToMarkdown('<p><img src="i.png" alt="图"></p><script>bad()</script>')).toBe('![图](i.png)');
  });

  test('嵌套列表缩进与单空格标记风格一致', () => {
    const markdown = htmlToMarkdown('<ul><li>甲<ul><li>乙</li></ul></li><li>丙</li></ul>');
    expect(markdown).toContain('- 甲\n  - 乙\n- 丙');
  });

  test('有序列表保留起始编号，无效起始编号回退到 1', () => {
    expect(htmlToMarkdown('<ol start="9"><li>甲</li><li>乙</li></ol>')).toBe('9. 甲\n10. 乙');
    expect(htmlToMarkdown('<ol start="bad"><li>甲</li></ol>')).toBe('1. 甲');
  });

  test('引用与删除线转换为对应语法', () => {
    expect(htmlToMarkdown('<blockquote><p>引用</p></blockquote><p><del>删</del></p>')).toContain('> 引用');
    expect(htmlToMarkdown('<p><del>删</del></p>')).toContain('~~删~~');
  });

  test('渲染模式粘贴富文本插入 Markdown，且可整体撤销', () => {
    const { view, read } = editor('前后', 1);
    view.contentDOM.dispatchEvent(pasteEvent('<p><strong>粗</strong>和 <a href="https://a.dev">链接</a></p>'));
    expect(read()).toBe('前**粗**和 [链接](https://a.dev)后');
    undo(view);
    expect(read()).toBe('前后');
    redo(view);
    expect(read()).toBe('前**粗**和 [链接](https://a.dev)后');
  });

  test('替换选区沿用文件行尾，撤销精确恢复 BOM 与混合行尾', () => {
    const original = '\uFEFF前\r\n替换\n尾\r末';
    const { view, read } = editor(original);
    view.dispatch({ selection: EditorSelection.single(3, 5) });
    view.contentDOM.dispatchEvent(pasteEvent('<p>第一段</p><p>第二段</p>'));
    expect(read()).toBe('\uFEFF前\r\n第一段\r\n\r\n第二段\n尾\r末');
    undo(view);
    expect(read()).toBe(original);
  });

  test('剪贴板没有 HTML 时保持默认粘贴', () => {
    const { view, read } = editor('原文');
    const event = pasteEvent('', [], '**纯文本**');
    view.contentDOM.dispatchEvent(event);
    expect(read()).toBe('原文**纯文本**');
  });

  test('源码模式粘贴不转换，避免 Markdown 字符被转义', () => {
    const { view, read } = editor('原文');
    toggleSourceMode(view);
    expect(view.state.field(sourceMode)).toBe(true);
    view.contentDOM.dispatchEvent(pasteEvent('<p><strong>粗</strong></p>', [], '# 源码'));
    expect(read()).toBe('原文# 源码');
  });

  test.each([
    ['```js\n代码\n```', 7],
    ['    代码', 5],
    ['前 `代码` 后', 4],
    ['<div>代码</div>', 6],
  ] as const)('代码或 HTML 中粘贴纯文本：%s', (text, position) => {
    const { view, read } = editor(text, position);
    view.contentDOM.dispatchEvent(pasteEvent('<p><strong>x</strong></p>', [], '*x*'));
    expect(read()).toBe(text.slice(0, position) + '*x*' + text.slice(position));
  });

  test('剪贴板带图片文件时交给图片粘贴流程', () => {
    const { view, read } = editor('原文');
    view.contentDOM.dispatchEvent(pasteEvent('<p><strong>粗</strong></p>', [new File(['i'], 'a.png', { type: 'image/png' })]));
    expect(read()).toBe('原文');
  });

  test('只读文档不转换', () => {
    const { view, read } = editor('原文', undefined, true);
    view.contentDOM.dispatchEvent(pasteEvent('<b>替换</b>', [], '替换'));
    expect(read()).toBe('原文');
  });

  test('转换失败与无可转换内容时回退到纯文本', () => {
    const { view, read } = editor('原文');
    const log = jest.spyOn(console, 'error').mockImplementation(() => {});
    jest.spyOn(TurndownService.prototype, 'turndown').mockImplementationOnce(() => { throw new Error('转换失败'); });
    view.contentDOM.dispatchEvent(pasteEvent('<b>甲</b>', [], '甲'));
    expect(read()).toBe('原文甲');
    expect(log).toHaveBeenCalledTimes(1);
    view.contentDOM.dispatchEvent(pasteEvent('<script>bad()</script>', [], '乙'));
    expect(read()).toBe('原文甲乙');
  });

  test('中文组合输入期间不转换格式', () => {
    const { view, read } = editor('原文');
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    view.contentDOM.dispatchEvent(pasteEvent('<b>中文</b>', [], '中文'));
    expect(read()).toBe('原文中文');
  });

  test('单元格输入框内的粘贴不改写文档', () => {
    const { view, read } = editor('原文');
    const input = document.createElement('input');
    view.contentDOM.appendChild(input);
    input.dispatchEvent(pasteEvent('<p><strong>粗</strong></p>'));
    expect(read()).toBe('原文');
  });
});
