import { ChangeSpec, EditorSelection, EditorState, StateCommand } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';

function inline(mark: string, name: string, markName = 'EmphasisMark'): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const selection = state.selection.main;
    let node = syntaxTree(state).resolveInner(selection.from, 1);
    while (node.name !== name && node.parent !== null) node = node.parent;
    const marks = node.name === name && selection.to <= node.to ? node.getChildren(markName) : [];
    const changes: ChangeSpec[] = [];
    if (marks.length === 2) {
      const content = state.sliceDoc(marks[0].to, marks[1].from);
      const padding = name === 'InlineCode' && /^ .* $/.test(content) && /\S/.test(content) ? 1 : 0;
      changes.push({ from: marks[0].from, to: marks[0].to + padding }, { from: marks[1].from - padding, to: marks[1].to });
    } else if (selection.empty && state.sliceDoc(selection.from - mark.length, selection.from) === mark
      && state.sliceDoc(selection.to, selection.to + mark.length) === mark
      && !/Emphasis/.test(syntaxTree(state).resolveInner(selection.from, 1).parent?.name ?? '')) {
      changes.push({ from: selection.from - mark.length, to: selection.to + mark.length });
    } else {
      const text = state.sliceDoc(selection.from, selection.to);
      const delimiter = name === 'InlineCode' ? '`'.repeat((text.match(/`+/g) ?? []).reduce((length, run) => Math.max(length, run.length), 0) + 1) : mark;
      const padding = name === 'InlineCode' && (/^`|`$/.test(text) || (/^ .* $/.test(text) && /\S/.test(text))) ? ' ' : '';
      const edge = delimiter + padding;
      // 只插入两端标记，保留选区内部的原始行尾。
      dispatch(state.update({
        changes: selection.empty
          ? { from: selection.from, insert: edge + padding + delimiter }
          : [{ from: selection.from, insert: edge }, { from: selection.to, insert: padding + delimiter }],
        selection: EditorSelection.single(selection.anchor + edge.length, selection.head + edge.length),
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
    const pattern = heading !== undefined ? /^( {0,3})(#{1,6})([ \t]+|$)/
      : style === 'blockquote' ? /^([ \t]*)(>)([ \t]?)/
        : /^([ \t]*)([-+*]|\d+[.)])([ \t]+)(?:(\[[ xX]\])(?:[ \t]+|$))?/;
    const matches = lines.map(line => pattern.exec(line.text));
    const remove = matches.length > 0 && matches.every(match => match !== null && (heading !== undefined
      ? match[2].length === Number(heading)
      : style === 'blockquote' ? true
        : style === 'taskList' ? /\[[ xX]\]/.test(match[0])
          : style === 'bulletList' ? /^[-+*]$/.test(match[2]) && !/\[[ xX]\]/.test(match[0]) : /^\d/.test(match[2])));
    const numbers = new Map<number, number>();
    const changes = lines.map((line, index) => {
      const match = matches[index];
      const indent = match?.[1] ?? (heading !== undefined ? /^ {0,3}/ : /^[ \t]*/).exec(line.text)?.[0] ?? '';
      const from = line.from + indent.length;
      const depth = indent.replace(/\t/g, '    ').length;
      for (const previous of numbers.keys()) if (previous > depth) numbers.delete(previous);
      const number = (numbers.get(depth) ?? 0) + 1;
      numbers.set(depth, number);
      const marker = heading !== undefined ? '#'.repeat(Number(heading))
        : style === 'blockquote' ? '>' : style === 'taskList' ? `- ${match?.[4] ?? '[ ]'}` : style === 'bulletList' ? '-' : `${number}.`;
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

const link: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const selection = state.selection.main;
  let node = syntaxTree(state).resolveInner(selection.from, 1);
  while (node.name !== 'Link' && node.parent !== null) node = node.parent;
  const marks = node.getChildren('LinkMark');
  if (node.name === 'Link' && selection.to <= node.to && state.sliceDoc(node.from, node.from + 1) === '[' && marks.length >= 2) {
    apply(state, dispatch, [{ from: node.from, to: node.from + 1 }, { from: marks[1].from, to: node.to }]);
  } else {
    dispatch(state.update({
      changes: [{ from: selection.from, insert: '[' }, { from: selection.to, insert: '](url)' }],
      selection: EditorSelection.single(selection.to + 3, selection.to + 6),
      annotations: isolateHistory.of('full'), userEvent: 'input.format', scrollIntoView: true,
    }));
  }
  return true;
};

const codeBlock: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const selection = state.selection.main;
  let node = syntaxTree(state).resolveInner(selection.from, 1);
  while (node.name !== 'FencedCode' && node.parent !== null) node = node.parent;
  const marks = node.getChildren('CodeMark');
  if (node.name === 'FencedCode' && node.parent?.name === 'Document' && selection.to <= node.to && marks.length === 2) {
    const first = state.doc.lineAt(marks[0].from);
    const last = state.doc.lineAt(marks[1].from);
    apply(state, dispatch, last.number === first.number + 1 ? [{ from: first.from, to: last.to }]
      : [{ from: first.from, to: first.to + 1 }, { from: last.from - 1, to: last.to }]);
  } else {
    const first = state.doc.lineAt(selection.from);
    const last = state.doc.lineAt(selection.empty ? selection.to : selection.to - 1);
    const text = state.sliceDoc(first.from, last.to);
    const fence = '`'.repeat((text.match(/`+/g) ?? []).reduce((length, run) => Math.max(length, run.length), 2) + 1);
    dispatch(state.update({
      changes: [{ from: first.from, insert: fence + '\n' }, { from: last.to, insert: '\n' + fence }],
      selection: EditorSelection.single(selection.anchor + fence.length + 1, selection.head + fence.length + 1),
      annotations: isolateHistory.of('full'), userEvent: 'input.format', scrollIntoView: true,
    }));
  }
  return true;
};

const horizontalRule: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const from = state.selection.main.to;
  const insert = (from > 0 ? '\n\n' : '') + '---\n\n';
  dispatch(state.update({ changes: { from, insert }, selection: { anchor: from + insert.length },
    annotations: isolateHistory.of('full'), userEvent: 'input.format', scrollIntoView: true }));
  return true;
};

export const formatCommands: Readonly<Partial<Record<string, StateCommand>>> = {
  bold: inline('**', 'StrongEmphasis'),
  italic: inline('*', 'Emphasis'),
  strikethrough: inline('~~', 'Strikethrough', 'StrikethroughMark'),
  inlineCode: inline('`', 'InlineCode', 'CodeMark'),
  link, codeBlock, horizontalRule,
  blockquote: block('blockquote'),
  taskList: block('taskList'),
  ...Object.fromEntries([1, 2, 3, 4, 5, 6].map(level => [`heading${level}`, block(`heading${level}`)])),
  bulletList: block('bulletList'),
  orderedList: block('orderedList'),
};
