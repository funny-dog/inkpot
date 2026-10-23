import { ChangeSpec, EditorSelection, EditorState, StateCommand } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';

function inline(mark: string, name: string): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const selection = state.selection.main;
    let node = syntaxTree(state).resolveInner(selection.from, 1);
    while (node.name !== name && node.parent !== null) node = node.parent;
    const marks = node.name === name && selection.to <= node.to ? node.getChildren('EmphasisMark') : [];
    const changes: ChangeSpec[] = [];
    if (marks.length === 2) {
      changes.push({ from: marks[0].from, to: marks[0].to }, { from: marks[1].from, to: marks[1].to });
    } else if (selection.empty && state.sliceDoc(selection.from - mark.length, selection.from) === mark
      && state.sliceDoc(selection.to, selection.to + mark.length) === mark
      && !/Emphasis/.test(syntaxTree(state).resolveInner(selection.from, 1).parent?.name ?? '')) {
      changes.push({ from: selection.from - mark.length, to: selection.to + mark.length });
    } else {
      // 只插入两端标记，保留选区内部的原始行尾。
      dispatch(state.update({
        changes: selection.empty
          ? { from: selection.from, insert: mark + mark }
          : [{ from: selection.from, insert: mark }, { from: selection.to, insert: mark }],
        selection: EditorSelection.single(selection.anchor + mark.length, selection.head + mark.length),
        annotations: isolateHistory.of('full'),
        userEvent: 'input.format',
        scrollIntoView: true,
      }));
      return true;
    }
    apply(state, dispatch, changes);
    return true;
  };
}

function block(style: string): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const range = state.selection.main;
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.empty ? range.to : range.to - 1).number;
    const lines = Array.from({ length: last - first + 1 }, (_, index) => state.doc.line(first + index))
      .filter(line => first === last || line.text.trim().length > 0);
    const heading = /^heading([1-6])$/.exec(style)?.[1];
    const pattern = heading !== undefined ? /^( {0,3})(#{1,6})([ \t]+|$)/ : /^([ \t]*)([-+*]|\d+[.)])([ \t]+)/;
    const matches = lines.map(line => pattern.exec(line.text));
    const remove = matches.length > 0 && matches.every(match => match !== null && (heading !== undefined
      ? match[2].length === Number(heading)
      : style === 'bulletList' ? /^[-+*]$/.test(match[2]) : /^\d/.test(match[2])));
    const numbers = new Map<number, number>();
    const changes = lines.map((line, index) => {
      const match = matches[index];
      const indent = match?.[1] ?? (heading !== undefined ? /^ {0,3}/ : /^[ \t]*/).exec(line.text)?.[0] ?? '';
      const from = line.from + indent.length;
      const depth = indent.replace(/\t/g, '    ').length;
      for (const previous of numbers.keys()) if (previous > depth) numbers.delete(previous);
      const number = (numbers.get(depth) ?? 0) + 1;
      numbers.set(depth, number);
      const marker = heading !== undefined ? '#'.repeat(Number(heading)) : style === 'bulletList' ? '-' : `${number}.`;
      if (remove) return { from, to: line.from + (match?.[0].length ?? 0), insert: '' };
      if (heading !== undefined && match !== null) return { from, to: from + match[2].length, insert: marker };
      return { from, to: line.from + (match?.[0].length ?? indent.length), insert: marker + ' ' };
    });
    apply(state, dispatch, changes);
    return true;
  };
}

function apply(state: EditorState, dispatch: Parameters<StateCommand>[0]['dispatch'], changes: ChangeSpec[]) {
  const changeSet = state.changes(changes);
  dispatch(state.update({
    changes: changeSet,
    selection: state.selection.map(changeSet, 1),
    annotations: isolateHistory.of('full'),
    userEvent: 'input.format',
    scrollIntoView: true,
  }));
}

export const formatCommands: Readonly<Partial<Record<string, StateCommand>>> = {
  bold: inline('**', 'StrongEmphasis'),
  italic: inline('*', 'Emphasis'),
  ...Object.fromEntries([1, 2, 3, 4, 5, 6].map(level => [`heading${level}`, block(`heading${level}`)])),
  bulletList: block('bulletList'),
  orderedList: block('orderedList'),
};
