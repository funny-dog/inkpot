import type { EditorState } from '@codemirror/state';

export interface Cell { from: number; to: number; text: string }
export interface Table { from: number; to: number; rows: Cell[][]; alignments: string[]; prefix: string }

export function rowCells(text: string, offset = 0): Cell[] {
  const boundaries = [-1];
  for (let index = 0; index < text.length; index++) {
    if (text[index] === '\\') { index++; continue; }
    if (text[index] === '|') boundaries.push(index);
  }
  boundaries.push(text.length);
  const cells = boundaries.slice(0, -1).map((start, index) => {
    const raw = text.slice(start + 1, boundaries[index + 1]);
    const from = start + 1 + raw.length - raw.trimStart().length;
    return { from: offset + from, to: offset + from + raw.trim().length, text: raw.trim() };
  });
  if (text.trimStart().startsWith('|')) cells.shift();
  if (text.trimEnd().endsWith('|') && boundaries[boundaries.length - 2] === text.trimEnd().length - 1) cells.pop();
  return cells;
}

export function readTable(state: EditorState, from: number, to: number): Table {
  const first = state.doc.lineAt(from).number;
  const last = state.doc.lineAt(to).number;
  const rows = Array.from({ length: last - first + 1 }, (_, index) => {
    const line = state.doc.line(first + index);
    return rowCells(line.text, line.from);
  });
  const alignments = rows.splice(1, 1)[0].map(cell => cell.text);
  return { from: state.doc.line(first).from, to: state.doc.line(last).to, rows, alignments, prefix: /^[ \t]*/.exec(state.doc.line(first).text)?.[0] ?? '' };
}

export function serializeTable(rows: string[][], alignments: string[], lineBreak: string, prefix = '') {
  const lines = rows.map(row => `${prefix}| ${row.join(' | ')} |`);
  lines.splice(1, 0, `${prefix}| ${alignments.join(' | ')} |`);
  return lines.join(lineBreak);
}
