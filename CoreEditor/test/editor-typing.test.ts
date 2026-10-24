import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { defaultKeymap, history, redo, undo } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { typingBindings } from '../editor/typing';

const views: EditorView[] = [];
function editor(text: string, position?: number, readOnly = false) {
  const source = sourceDocument(text);
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({
      doc: source.doc,
      selection: EditorSelection.cursor(position ?? source.doc.length),
      extensions: [...source.extensions, ...writingExtensions, ...liveEditing,
        history(), keymap.of(defaultKeymap), EditorState.readOnly.of(readOnly)],
    }),
  });
  views.push(view);
  view.focus();
  return {
    view,
    read: () => source.read(view.state),
    press(key: string) {
      view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {
        key, keyCode: key === 'Enter' ? 13 : 8, bubbles: true, cancelable: true,
      }));
    },
  };
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

describe('Inkpot 连续写作', () => {
  test.each(['- ', '* ', '+ ', '3. ', '9) ', '> '])('回车续写 %s，空项再次回车退出，分别撤销', prefix => {
    const original = `${prefix}中文`;
    const { view, read, press } = editor(original);
    const next = prefix === '3. ' ? '4. ' : prefix === '9) ' ? '10) ' : prefix;
    press('Enter');
    expect(read()).toBe(`${original}\n${next}`);
    const continued = read();
    press('Enter');
    expect(read()).toBe(`${original}\n`);
    undo(view);
    expect(read()).toBe(continued);
    undo(view);
    expect(read()).toBe(original);
    redo(view);
    expect(read()).toBe(continued);
  });

  test('中途续项保留后续原文编号、空格及混合行尾', () => {
    const original = '1. 甲  \r\n2. 乙\n尾\r末';
    const { view, read, press } = editor(original, 6);
    press('Enter');
    expect(read()).toBe('1. 甲  \r\n2. \r\n2. 乙\n尾\r末');
    undo(view);
    expect(read()).toBe(original);
  });

  test('在条目中间分行保留两边文字和标记风格', () => {
    const { read, press } = editor('* 前后', 3);
    press('Enter');
    expect(read()).toBe('* 前\n* 后');
  });

  test('含空行的列表续写只增加当前一行，不额外插入空段落', () => {
    const { read, press } = editor('- 甲\n\n- 乙', 3);
    press('Enter');
    expect(read()).toBe('- 甲\n- \n\n- 乙');
  });

  test.each([
    ['- 父\n  - 子', '- 父\n  - 子\n  - ', '- 父\n  - 子\n- '],
    ['> > 引用', '> > 引用\n> > ', '> > 引用\n> '],
    ['> - 项目', '> - 项目\n> - ', '> - 项目\n> '],
  ])('嵌套结构续写并逐层退出：%s', (text, continued, exited) => {
    const { read, press } = editor(text);
    press('Enter');
    expect(read()).toBe(continued);
    press('Enter');
    expect(read()).toBe(exited);
    press('Enter');
    expect(read()).toBe(exited.slice(0, exited.lastIndexOf('\n') + 1));
  });

  test.each([
    ['- 内容', 2, '内容'],
    ['- 前\n- 内容', 6, '- 前\n  内容'],
    ['- 父\n  - 内容', 8, '- 父\n  内容'],
    ['> 内容', 2, '内容'],
    ['> > 内容', 4, '> 内容'],
  ])('内容起点退格取消当前层标记且可撤销：%s', (text, position, expected) => {
    const { view, read, press } = editor(text, position);
    press('Backspace');
    expect(read()).toBe(expected);
    undo(view);
    expect(read()).toBe(text);
  });

  test.each(['# 标题', '###### 标题', '正文', '```\n- 代码', '<script>\n- 字面'])('普通正文、标题和原始代码回车不续写伪标记：%s', text => {
    const { read, press } = editor(text);
    press('Enter');
    expect(read()).toBe(`${text}\n`);
  });

  test('选区替换使用默认换行，不误续写或丢失未选文字', () => {
    const { view, read, press } = editor('- 前后');
    view.dispatch({ selection: EditorSelection.single(4, 3) });
    press('Enter');
    expect(read()).toBe('- 前\n');
  });

  test('源码模式下沿用相同续写与退出规则', () => {
    const { view, read, press } = editor('> 内容');
    toggleSourceMode(view);
    press('Enter');
    expect(read()).toBe('> 内容\n> ');
    press('Enter');
    expect(read()).toBe('> 内容\n');
  });

  test('组合输入和只读状态不触发结构编辑', () => {
    const { view, read } = editor('- 中文');
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    for (const binding of typingBindings) expect(binding.run?.(view)).toBe(true);
    expect(read()).toBe('- 中文');
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    const locked = editor('- 只读', undefined, true);
    for (const binding of typingBindings) expect(binding.run?.(locked.view)).toBe(true);
    expect(locked.read()).toBe('- 只读');
  });
});
