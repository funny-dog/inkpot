import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { indentCompartment, indentLines, indentWidth, outdentLines } from '../editor/indent';

const views: EditorView[] = [];
function editor(text: string, anchor: number, head = anchor, width = 2) {
  const view = new EditorView({
    parent: document.body,
    state: EditorState.create({ doc: text, selection: EditorSelection.single(anchor, head), extensions: [indentCompartment.of(indentWidth(width))] }),
  });
  views.push(view);
  return view;
}
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

describe('Tab 缩进', () => {
  test('正文光标处插入缩进宽度的空格', () => {
    const view = editor('中文', 1);
    indentLines(view);
    expect(view.state.doc.toString()).toBe('中  文');
    const wide = editor('ab', 0, 0, 4);
    indentLines(wide);
    expect(wide.state.doc.toString()).toBe('    ab');
  });

  test('无序列表整行缩进，⇧Tab 退回父级', () => {
    const view = editor('- 一\n- 二', 5);
    indentLines(view);
    expect(view.state.doc.toString()).toBe('- 一\n  - 二');
    outdentLines(view);
    expect(view.state.doc.toString()).toBe('- 一\n- 二');
  });

  test('有序列表按上一项正文起点缩进，保证嵌套', () => {
    const view = editor('1. 一\n2. 二', 7);
    indentLines(view);
    expect(view.state.doc.toString()).toBe('1. 一\n   2. 二');
    outdentLines(view);
    expect(view.state.doc.toString()).toBe('1. 一\n2. 二');
  });

  test('多行选区逐行缩进并跳过空行', () => {
    const view = editor('甲\n\n乙', 0, 4);
    indentLines(view);
    expect(view.state.doc.toString()).toBe('  甲\n\n  乙');
    outdentLines(view);
    expect(view.state.doc.toString()).toBe('甲\n\n乙');
  });

  test('只读时不处理', () => {
    const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: 'a', extensions: [EditorState.readOnly.of(true)] }) });
    views.push(view);
    expect(indentLines(view)).toBe(false);
    expect(view.state.doc.toString()).toBe('a');
  });
});
