import { describe, expect, test } from '@jest/globals';
import { EditorState, Transaction } from '@codemirror/state';
import { history, redo, undo } from '@codemirror/commands';
import { sourceDocument } from '../mvp/source';

function document(text: string) {
  const source = sourceDocument(text);
  const target = {
    state: EditorState.create({ doc: source.doc, extensions: [...source.extensions, history()] }),
    dispatch(transaction: Transaction) { target.state = transaction.state; },
  };
  return { target, read: () => source.read(target.state) };
}

describe('MVP 原文保存', () => {
  test.each(['', '# 中文 👨‍👩‍👧\n', 'a\r\nb\nc\rd\r\n', 'e\u0301\t  \n'])('打开不重写原文 %j', text => {
    const { target, read } = document(text);
    target.dispatch(target.state.update({ selection: { anchor: target.state.doc.length } }));
    expect(read()).toBe(text);
  });

  test('局部编辑保留混合行尾，新行沿用首个行尾', () => {
    const { target, read } = document('a\r\nb\nc\rd');
    target.dispatch(target.state.update({ changes: { from: 2, to: 3, insert: '中文\n新行' } }));
    expect(read()).toBe('a\r\n中文\r\n新行\nc\rd');
  });

  test('删除、撤销和重做保留被删除的不同类型行尾', () => {
    const original = 'a\r\nb\nc\rd';
    const { target, read } = document(original);
    target.dispatch(target.state.update({ changes: { from: 1, to: 6, insert: 'x\ny' } }));
    const edited = read();
    expect(undo(target)).toBe(true);
    expect(read()).toBe(original);
    expect(redo(target)).toBe(true);
    expect(read()).toBe(edited);
  });

  test('合并历史及多段修改的撤销恢复原文', () => {
    const original = 'a\r\nb\nc\rd\ne';
    const { target, read } = document(original);
    target.dispatch(target.state.update({
      changes: [{ from: 1, to: 2, insert: '' }, { from: 5, to: 6, insert: '' }],
      userEvent: 'delete.backward',
    }));
    target.dispatch(target.state.update({ changes: { from: 1, to: 3, insert: '' }, userEvent: 'delete.backward' }));
    while (undo(target)) { /* 撤销到文档初始状态。 */ }
    expect(read()).toBe(original);
    while (redo(target)) { /* 重做后再次检查逆操作。 */ }
    while (undo(target)) { /* 合并历史不能丢失行尾元数据。 */ }
    expect(read()).toBe(original);
  });
});
