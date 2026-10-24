import { describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { sourceDocument } from '../editor/source';
import { documentStats, statsExtension } from '../editor/stats';

function stats(text: string) {
  return documentStats(EditorState.create({ doc: sourceDocument(text).doc }));
}

describe('Inkpot 字数统计', () => {
  test('纯中文按字计数', () => {
    expect(stats('你好世界').words).toBe(4);
    expect(stats('你好世界').characters).toBe(4);
    expect(stats('你好世界').lines).toBe(1);
  });

  test('英文按词计数，数字串算一词', () => {
    expect(stats('hello world 2026').words).toBe(3);
    expect(stats("don't stop").words).toBe(2);
  });

  test('中英混合：中日韩逐字加西文按词', () => {
    expect(stats('你好 world 2026').words).toBe(4);
    expect(stats('カタカナと日本語').words).toBe(8);
  });

  test('空白与标点不计数，markdown 标记计入字符', () => {
    expect(stats('# 标题 **加粗**').words).toBe(4);
    expect(stats('# 标题 **加粗**').characters).toBe(11);
  });

  test('空文档与多行', () => {
    expect(stats('')).toEqual({ words: 0, characters: 0, lines: 1 });
    expect(stats('第一行\n\n第三行').lines).toBe(3);
    expect(stats('第一行\n\n第三行').characters).toBe(6);
  });

  test('十万字符在阈值内完成', () => {
    const text = '中文与 english 混合的正文。\n'.repeat(5000);
    const started = Date.now();
    const result = stats(text);
    expect(result.characters).toBe(90000);
    expect(Date.now() - started).toBeLessThan(200);
  });
});

describe('Inkpot 字数统计的增量更新', () => {
  function editorState(text: string) {
    return EditorState.create({ doc: sourceDocument(text).doc, extensions: statsExtension });
  }
  function full(current: EditorState) {
    return documentStats(EditorState.create({ doc: current.doc }));
  }

  test('输入、跨行删除、换行合并与多处改动后与全文重算一致', () => {
    let current = editorState("第一行 hello\n第二行 don't\n\n第四行 world 2026");
    const edits = [
      { changes: { from: 3, insert: '新增' } },
      { changes: { from: 8, to: 20 } },
      { changes: { from: current.doc.line(1).to, to: current.doc.line(1).to + 1 } },
      { changes: [{ from: 0, insert: 'start ' }, { from: 5, to: 7, insert: '中\n文' }, { from: 12, insert: '\n\n' }] },
      // 改动落在单词中间：拆开、再拼回撇号连写。
      { changes: { from: 0, to: 0, insert: "it's" } },
      { changes: { from: 2, to: 3, insert: ' ' } },
    ];
    for (const edit of edits) {
      current = current.update(edit).state;
      expect(documentStats(current)).toEqual(full(current));
    }
  });

  test('随机编辑序列保持与全文重算一致', () => {
    let seed = 7;
    const random = (limit: number) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % limit; };
    const pieces = ['中', 'ab', ' ', '\n', "'", 'x1', '日本', '\n\n', ''];
    let current = editorState('中文 english 混合\n第二行\n');
    for (let step = 0; step < 300; step++) {
      const length = current.doc.length;
      const from = random(length + 1);
      const to = Math.min(length, from + random(4));
      current = current.update({ changes: { from, to, insert: pieces[random(pieces.length)] } }).state;
      expect(documentStats(current)).toEqual(full(current));
    }
  });

  test('只移动光标时不重新统计', () => {
    const current = editorState('你好 world');
    const moved = current.update({ selection: { anchor: 2 } }).state;
    expect(moved.field(statsExtension)).toBe(current.field(statsExtension));
    expect(documentStats(moved).words).toBe(3);
  });
});
