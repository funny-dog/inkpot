import { describe, expect, test } from '@jest/globals';
import { EditorState, Transaction } from '@codemirror/state';
import { history, redo, undo } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { legacySourceDocument } from './utils/legacy-source';

function document(text: string) {
  const source = sourceDocument(text);
  const target = {
    state: EditorState.create({ doc: source.doc, extensions: [...source.extensions, history()] }),
    dispatch(transaction: Transaction) { target.state = transaction.state; },
  };
  return { target, read: () => source.read(target.state) };
}

describe('Inkpot 原文保存', () => {
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

  test('首个行尾与多数行尾不同时，新行沿用首个行尾，删除后撤销恢复多数行尾', () => {
    const original = 'a\nb\r\nc\r\nd\r\ne';
    const { target, read } = document(original);
    target.dispatch(target.state.update({ changes: { from: 4, insert: '新\n行' } }));
    expect(read()).toBe('a\nb\r\n新\n行c\r\nd\r\ne');
    target.dispatch(target.state.update({ changes: { from: 8, to: 10 } }));
    expect(read()).toBe('a\nb\r\n新\n行c\r\ne');
    while (undo(target)) { /* 逐步撤销到初始状态。 */ }
    expect(read()).toBe(original);
    while (redo(target)) { /* 重做两次修改。 */ }
    expect(read()).toBe('a\nb\r\n新\n行c\r\ne');
  });

  test.each([
    ['统一 LF', 'a\nb\nc\nd\n'],
    ['统一 CRLF', 'a\r\nb\r\nc\r\n'],
    ['混合且首个为少数', 'a\nb\r\nc\r\nd\re\r\n'],
    ['三种各半', 'a\rb\nc\r\nd\re\nf\r\n'],
    ['无换行', 'abc'],
  ])('随机编辑、撤销与重做与旧实现逐字节一致：%s', (_name, original) => {
    const current = document(original);
    const legacySource = legacySourceDocument(original);
    const legacy = {
      state: EditorState.create({ doc: legacySource.doc, extensions: [...legacySource.extensions, history()] }),
      dispatch(transaction: Transaction) { legacy.state = transaction.state; },
    };
    let seed = 11;
    const random = (limit: number) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % limit; };
    const pieces = ['x', '\n', '中\n文', '', '\n\n', 'ab'];
    for (let step = 0; step < 400; step++) {
      const action = random(10);
      if (action < 2) {
        expect(undo(current.target)).toBe(undo(legacy));
      } else if (action < 3) {
        expect(redo(current.target)).toBe(redo(legacy));
      } else {
        const length = current.target.state.doc.length;
        const from = random(length + 1);
        const to = Math.min(length, from + random(5));
        const spec = { changes: { from, to, insert: pieces[random(pieces.length)] }, userEvent: random(2) === 0 ? 'input.type' : 'delete.backward' };
        current.target.dispatch(current.target.state.update(spec));
        legacy.dispatch(legacy.state.update(spec));
      }
      expect(current.read()).toBe(legacySource.read(legacy.state));
    }
    while (undo(current.target)) { /* 撤销全部修改。 */ }
    expect(current.read()).toBe(original);
  });
});
