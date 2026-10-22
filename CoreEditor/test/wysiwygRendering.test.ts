import { afterEach, describe, expect, jest, test } from '@jest/globals';
import { ensureSyntaxTree } from '@codemirror/language';
import { history, undo, redo } from '../src/@vendor/commands/history';
import { renderedBlocks } from '../src/wysiwyg/render';
import { htmlToMarkdown, richPaste } from '../src/wysiwyg/paste';
import { liveModeExtension, setLiveMode } from '../src/wysiwyg';
import { Config } from '../src/config';
import { setUp } from './utils/editor';
import { vimModeExtension, setVimMode } from '../src/wysiwyg/vim';

jest.mock('../src/wysiwyg/assets', () => ({
  loadKatex: async () => ({ render: (source: string, target: HTMLElement) => { target.textContent = `math:${source}`; } }),
  loadMermaid: async () => ({ render: async () => ({ svg: '<svg aria-label="图表"></svg>' }) }),
}));

afterEach(() => window.editor.destroy());

describe('实时渲染与编辑', () => {
  test('未对齐表格在打开、选区变化、切换时不重排，编辑可撤销', async () => {
    const source = '# 标题\n\n| A| B |\n|---|:---:|\n|一| two |\n\n后文';
    window.config = { liveMode: true } as Config;
    setUp(source, [history(), liveModeExtension()]);
    ensureSyntaxTree(window.editor.state, source.length, 5000);
    window.editor.dispatch({ selection: { anchor: source.length } });
    await new Promise(resolve => setTimeout(resolve, 30));
    expect(window.editor.state.doc.toString()).toBe(source);
    expect(window.editor.dom.querySelector('.km-table')).not.toBeNull();
    setLiveMode(false);
    setLiveMode(true);
    window.editor.dispatch({ selection: { anchor: 2 } });
    await new Promise(resolve => setTimeout(resolve, 10));
    expect(window.editor.state.doc.toString()).toBe(source);
    const from = source.indexOf('two');
    window.editor.dispatch({ changes: { from, to: from + 3, insert: '编辑' }, userEvent: 'input' });
    expect(window.editor.state.doc.toString()).toContain('编辑');
    expect(undo(window.editor)).toBe(true);
    expect(window.editor.state.doc.toString()).toBe(source);
    expect(redo(window.editor)).toBe(true);
    expect(window.editor.state.doc.toString()).toContain('编辑');
  });

  test('公式和图表在编辑时保留源码与预览，行内公式跳过代码', () => {
    const source = '正文 $x$ 和 `$code$`\n\n$$\nx^2\n$$\n\n```mermaid\ngraph TD; A-->B\n```\n\n结尾';
    window.config = { liveMode: true } as Config;
    setUp(source, liveModeExtension());
    ensureSyntaxTree(window.editor.state, source.length, 5000);
    window.editor.dispatch({ selection: { anchor: source.length } });
    expect(window.editor.state.field(renderedBlocks).size).toBe(3);
    const block = source.indexOf('x^2');
    window.editor.dispatch({ selection: { anchor: block } });
    const ranges: { from: number; to: number }[] = [];
    window.editor.state.field(renderedBlocks).between(0, source.length, (from, to) => { ranges.push({ from, to }); });
    expect(ranges.some(range => range.from === range.to && range.from === source.indexOf('$$', block) + 2)).toBe(true);
    expect(window.editor.state.doc.toString()).toBe(source);
  });

  test('富文本标题、列表、链接与表格转 Markdown，脚本被忽略', () => {
    setUp('');
    const result = htmlToMarkdown('<h1>标题</h1><ul><li>项目</li></ul><p><a href="https://example.com">链接</a></p><table><tr><th>A</th><th>B</th></tr><tr><td>1|2</td><td>3</td></tr></table><script>alert(1)</script>');
    expect(result).toContain('# 标题');
    expect(result).toMatch(/-\s+项目/);
    expect(result).toContain('[链接](https://example.com)');
    expect(result).toContain('| --- | --- |');
    expect(result).toContain('1\\|2');
    expect(result).not.toContain('alert');
  });

  test('富文本粘贴替换选区并可撤销', () => {
    setUp('替换这里', [history(), richPaste]);
    window.editor.dispatch({ selection: { anchor: 0, head: 4 } });
    const event = new Event('paste', { bubbles: true, cancelable: true });
    Object.defineProperty(event, 'clipboardData', { value: { getData: () => '<b>内容</b>' } });
    window.editor.contentDOM.dispatchEvent(event);
    expect(window.editor.state.doc.toString()).toBe('**内容**');
    undo(window.editor);
    expect(window.editor.state.doc.toString()).toBe('替换这里');
  });

  test('vim 默认关闭，开启与关闭不修改文档', async () => {
    window.config = {} as Config;
    setUp('vim 内容', vimModeExtension());
    await setVimMode(true);
    await setVimMode(false);
    expect(window.editor.state.doc.toString()).toBe('vim 内容');
  });
});

test('点击单元格输入只修改对应源码，保留其他空格并支持撤销', () => {
  const source = '|A| B |\n|---|---|\n| one |two|\n\n尾部';
  window.config = { liveMode: true } as Config;
  setUp(source, [history(), liveModeExtension()]);
  const input = window.editor.dom.querySelector<HTMLInputElement>('tr:last-child td:last-child input');
  expect(input).not.toBeNull();
  if (input === null) return;
  input.focus();
  input.value = '中文';
  input.dispatchEvent(new InputEvent('input', { bubbles: true }));
  expect(window.editor.state.doc.toString()).toBe(source.replace('two', '中文'));
  expect(document.activeElement).toBe(input);
  undo(window.editor);
  expect(window.editor.state.doc.toString()).toBe(source);
});

test('空单元格与转义分隔符可正确定位', () => {
  setUp('');
  expect(rowCells('| a\\|b | |c|').map(cell => cell.text)).toEqual(['a\\|b', '', 'c']);
  expect(rowCells('a | b').map(cell => cell.text)).toEqual(['a', 'b']);
});

import { rowCells } from '../src/wysiwyg/tables/model';

test('只读表格禁用输入，公式高亮不修改源码', () => {
  const source = '| A | B |\n| --- | --- |\n| 1 | 2 |\n\n==高亮== 与 `==代码==`';
  window.config = { liveMode: true } as Config;
  setUp(source, [EditorState.readOnly.of(true), liveModeExtension()]);
  window.editor.dispatch({ selection: { anchor: source.length } });
  expect(window.editor.dom.querySelector<HTMLInputElement>('.km-table input')?.disabled).toBe(true);
  expect(window.editor.dom.querySelectorAll('.km-highlight')).toHaveLength(1);
  expect(window.editor.state.doc.toString()).toBe(source);
});

import { EditorState } from '@codemirror/state';
