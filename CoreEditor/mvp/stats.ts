import { EditorState } from '@codemirror/state';

export interface DocumentStats {
  /** 中日韩文字按字计数，其他文字按词计数 */
  words: number;
  /** 不含换行的全部字符数 */
  characters: number;
  lines: number;
}

// 中日韩字符逐字计数，其余连续的字母数字串按词计数（Typora 口径）。
const wordPattern = /[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7A3]|[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu;

export function documentStats(state: EditorState): DocumentStats {
  const doc = state.doc;
  let words = 0;
  let characters = 0;
  for (let number = 1; number <= doc.lines; number++) {
    const text = doc.line(number).text;
    characters += text.length;
    words += (text.match(wordPattern) ?? []).length;
  }
  return { words, characters, lines: doc.lines };
}
