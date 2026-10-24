import { EditorState, StateField, Text } from '@codemirror/state';

export interface DocumentStats {
  /** 中日韩文字按字计数，其他文字按词计数 */
  words: number;
  /** 不含换行的全部字符数 */
  characters: number;
  lines: number;
}

// 中日韩字符逐字计数，其余连续的字母数字串按词计数（Typora 口径）。
const wordPattern = /[㐀-䶿一-鿿豈-﫿぀-ヿ가-힣]|[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu;

function countLines(doc: Text, first: number, last: number) {
  let words = 0;
  for (let number = first; number <= last; number++) words += (doc.line(number).text.match(wordPattern) ?? []).length;
  return words;
}

// 统计受改动影响的行：词不跨行，按行累加的结果与全文重算一致。相邻或重叠的改动合并后每行只算一次。
function countTouchedLines(doc: Text, ranges: readonly { from: number; to: number }[]) {
  let words = 0;
  let last = 0;
  for (const range of ranges) {
    const first = Math.max(doc.lineAt(range.from).number, last + 1);
    const end = doc.lineAt(range.to).number;
    if (first <= end) words += countLines(doc, first, end);
    last = Math.max(last, end);
  }
  return words;
}

// 字数随编辑增量更新：只减去旧文档中被改动的行、加上新文档中对应的行，光标移动不重新统计。
const wordCount = StateField.define<number>({
  create: state => countLines(state.doc, 1, state.doc.lines),
  update(value, transaction) {
    if (!transaction.docChanged) return value;
    const before: { from: number; to: number }[] = [];
    const after: { from: number; to: number }[] = [];
    transaction.changes.iterChangedRanges((fromA, toA, fromB, toB) => {
      before.push({ from: fromA, to: toA });
      after.push({ from: fromB, to: toB });
    });
    return value - countTouchedLines(transaction.startState.doc, before) + countTouchedLines(transaction.state.doc, after);
  },
});

export const statsExtension = wordCount;

export function documentStats(state: EditorState): DocumentStats {
  const doc = state.doc;
  const words = state.field(wordCount, false) ?? countLines(doc, 1, doc.lines);
  // 每个换行在文档长度中占一个字符。
  return { words, characters: doc.length - (doc.lines - 1), lines: doc.lines };
}
