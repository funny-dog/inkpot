import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { history, redo, undo } from '@codemirror/commands';
import { getSearchQuery, setSearchQuery, SearchQuery } from '@codemirror/search';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { formatCommands } from '../mvp/format';
import { searchCommands } from '../mvp/search';

const views: EditorView[] = [];
function editor(text: string, anchor = 0, head = anchor) {
  const source = sourceDocument(text);
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({
      doc: source.doc,
      selection: EditorSelection.single(anchor, head),
      extensions: [...source.extensions, ...writingExtensions, history()],
    }),
  });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

describe('MVP 基础高亮与格式操作', () => {
  test('常用格式和查找快捷键绑定到同一套操作', () => {
    const { view, read } = editor('文字', 0, 2);
    view.focus();
    const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform);
    function press(key: string, keyCode: number, shiftKey = false) {
      view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
        key, keyCode, shiftKey, metaKey: mac, ctrlKey: !mac, bubbles: true, cancelable: true,
      }));
    }
    press('b', 66);
    expect(read()).toBe('**文字**');
    undo(view);
    press('i', 73);
    expect(read()).toBe('*文字*');
    undo(view);
    press('2', 50);
    expect(read()).toBe('## 文字');
    undo(view);
    press('&', 55, true);
    expect(read()).toBe('1. 文字');
    undo(view);
    press('*', 56, true);
    expect(read()).toBe('- 文字');
    undo(view);
    press('f', 70);
    expect(view.dom.querySelector('[role=search]')).not.toBeNull();
    expect(read()).toBe('文字');
  });

  test('高亮解析常用语法，保留所有源码与混合行尾', () => {
    const text = '# 标题\r\n**粗体** *斜体* [链接](https://example.com)\n- 列表\r\n```\n代码\n```';
    const { view, read } = editor(text);
    const names: string[] = [];
    syntaxTree(view.state).iterate({ enter: node => { names.push(node.name); } });
    expect(names).toEqual(expect.arrayContaining(['ATXHeading1', 'StrongEmphasis', 'Emphasis', 'Link', 'ListItem', 'FencedCode']));
    expect(view.contentDOM.querySelector('span[class]')).not.toBeNull();
    expect(read()).toBe(text);
  });

  test.each([['bold', '**'], ['italic', '*']])('%s 保留反向选区，切换后能分步撤销', (name, mark) => {
    const { view, read } = editor('前 中文 后', 4, 2);
    expect(formatCommands[name]?.(view)).toBe(true);
    expect(read()).toBe(`前 ${mark}中文${mark} 后`);
    expect(view.state.selection.main.anchor).toBeGreaterThan(view.state.selection.main.head);
    formatCommands[name]?.(view);
    expect(read()).toBe('前 中文 后');
    undo(view);
    expect(read()).toBe(`前 ${mark}中文${mark} 后`);
    undo(view);
    expect(read()).toBe('前 中文 后');
  });

  test.each([['bold', '__中文__'], ['italic', '_中文_']])('%s 能在已有格式中移除下划线标记', (name, text) => {
    const { view, read } = editor(text, 3);
    formatCommands[name]?.(view);
    expect(read()).toBe('中文');
  });

  test('在粗体中增加斜体不会拆坏粗体标记', () => {
    const { view, read } = editor('**中文**', 2, 4);
    formatCommands.italic?.(view);
    expect(read()).toBe('***中文***');
    formatCommands.italic?.(view);
    expect(read()).toBe('**中文**');
  });

  test('跨行加粗只改两端，保留内部行尾与空格', () => {
    const original = '一  \r\n二\n三';
    const { view, read } = editor(original, 0, 7);
    formatCommands.bold?.(view);
    expect(read()).toBe(`**${original}**`);
    undo(view);
    expect(read()).toBe(original);
  });

  test('空选区加粗放置光标，再次切换移除空标记', () => {
    const { view, read } = editor('');
    formatCommands.bold?.(view);
    expect(read()).toBe('****');
    expect(view.state.selection.main.head).toBe(2);
    formatCommands.bold?.(view);
    expect(read()).toBe('');
  });

  test('标题操作排除仅选到行首的末行，保留混合行尾', () => {
    const original = '甲\r\n乙\n尾';
    const { view, read } = editor(original, 0, 4);
    formatCommands.heading2?.(view);
    expect(read()).toBe('## 甲\r\n## 乙\n尾');
    formatCommands.heading2?.(view);
    expect(read()).toBe(original);
    undo(view);
    expect(read()).toBe('## 甲\r\n## 乙\n尾');
    undo(view);
    expect(read()).toBe(original);
  });

  test('标题换级保留缩进及标记后的空格', () => {
    const { view, read } = editor('  ###   原文', 8);
    formatCommands.heading1?.(view);
    expect(read()).toBe('  #   原文');
  });

  test.each(['bulletList', 'orderedList'])('%s 只改前缀，切换与撤销保留原始行尾', name => {
    const original = '甲\r\n乙\n\n尾';
    const { view, read } = editor(original, 0, 4);
    formatCommands[name]?.(view);
    expect(read()).toBe(name === 'bulletList' ? '- 甲\r\n- 乙\n\n尾' : '1. 甲\r\n2. 乙\n\n尾');
    formatCommands[name]?.(view);
    expect(read()).toBe(original);
    undo(view);
    undo(view);
    expect(read()).toBe(original);
  });

  test('列表转换保留缩进，嵌套层级分别编号', () => {
    const { view, read } = editor('- 甲\r\n  * 子项\n- 乙\n  - 另一子项', 0, 23);
    formatCommands.orderedList?.(view);
    expect(read()).toBe('1. 甲\r\n  1. 子项\n2. 乙\n  1. 另一子项');
  });
});

describe('MVP 当前文档查找替换', () => {
  function panel(view: EditorView) {
    searchCommands.find(view);
    const find = view.dom.querySelector<HTMLInputElement>('input[name=search]');
    const replace = view.dom.querySelector<HTMLInputElement>('input[name=replace]');
    if (find === null || replace === null) throw new Error('搜索栏未打开');
    return { find, replace };
  }
  function fill(field: HTMLInputElement, text: string) {
    field.value = text;
    field.dispatchEvent(new InputEvent('input', { bubbles: true }));
  }
  function click(view: EditorView, name: string) {
    const button = view.dom.querySelector<HTMLButtonElement>(`button[name=${name}]`);
    if (button === null) throw new Error(`找不到按钮 ${name}`);
    button.click();
  }

  test('普通文本查找可循环前后导航，关闭不修改原文', () => {
    const original = '中文\r\n中文\n尾';
    const { view, read } = editor(original);
    const { find } = panel(view);
    fill(find, '中文');
    click(view, 'next');
    expect(view.state.selection.main.from).toBe(0);
    click(view, 'next');
    expect(view.state.selection.main.from).toBe(3);
    click(view, 'next');
    expect(view.state.selection.main.from).toBe(0);
    click(view, 'previous');
    expect(view.state.selection.main.from).toBe(3);
    find.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    expect(view.dom.querySelector('[role=search]')).toBeNull();
    expect(read()).toBe(original);
  });

  test('单项替换和全部替换分别撤销，保留未涉及的行尾', () => {
    const original = '中文\r\n中文\n尾';
    const { view, read } = editor(original);
    const { find, replace } = panel(view);
    fill(find, '中文');
    fill(replace, '替换');
    click(view, 'next');
    click(view, 'replace');
    expect(read()).toBe('替换\r\n中文\n尾');
    click(view, 'replaceAll');
    expect(read()).toBe('替换\r\n替换\n尾');
    undo(view);
    expect(read()).toBe('替换\r\n中文\n尾');
    undo(view);
    expect(read()).toBe(original);
    redo(view);
    expect(read()).toBe('替换\r\n中文\n尾');
  });

  test('点号和反斜杠按字面查找，没有匹配时反馈', () => {
    const { view, read } = editor('a.b aXb \\n\r\n尾');
    const { find, replace } = panel(view);
    fill(find, 'a.b');
    fill(replace, '字');
    click(view, 'replaceAll');
    expect(read()).toBe('字 aXb \\n\r\n尾');
    fill(find, '\\n');
    click(view, 'replaceAll');
    expect(read()).toBe('字 aXb 字\r\n尾');
    searchCommands.findNext(view);
    expect(view.dom.querySelector('[role=status]')?.textContent).toBe('未找到匹配项');
  });

  test('搜索栏接收外部查询更新，组合输入期间不触发导航或覆盖输入', () => {
    const { view } = editor('中文');
    const { find } = panel(view);
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: '旧查询', literal: true })) });
    expect(find.value).toBe('旧查询');
    find.value = '正在选词';
    find.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true }));
    find.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, isComposing: true }));
    view.dispatch({ selection: { anchor: 1 } });
    expect(find.value).toBe('正在选词');
    expect(getSearchQuery(view.state).search).toBe('旧查询');
    find.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    expect(getSearchQuery(view.state).search).toBe('正在选词');
  });
});
