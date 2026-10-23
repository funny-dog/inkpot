import { EditorSelection, EditorState, Range, StateEffect, StateField } from '@codemirror/state';
import { indentUnit, syntaxTree } from '@codemirror/language';
import { cursorLineDown, cursorLineUp, isolateHistory } from '@codemirror/commands';
import { Decoration, EditorView, KeyBinding, WidgetType } from '@codemirror/view';
import { SyntaxNode } from '@lezer/common';

const editLanguage = StateEffect.define<number | null>();
export const editingCodeLanguage = StateField.define<number | null>({
  create: () => null,
  update(value, transaction) {
    let position = value === null ? null : transaction.changes.mapPos(value, 1);
    for (const effect of transaction.effects) if (effect.is(editLanguage)) position = effect.value;
    if (position !== null) {
      const line = transaction.state.doc.lineAt(position);
      const selection = transaction.state.selection.main;
      if (selection.from < line.from || selection.to > line.to) position = null;
    }
    return position;
  },
});

function fences(node: SyntaxNode, state: EditorState) {
  const marks = node.getChildren('CodeMark');
  if (marks.length === 0) return;
  const opening = marks[0];
  const closing = marks.length > 1 ? marks[marks.length - 1] : undefined;
  return {
    node, opening, closing,
    first: state.doc.lineAt(opening.from),
    last: closing === undefined ? undefined : state.doc.lineAt(closing.from),
    info: node.getChild('CodeInfo'),
  };
}

function currentCode(view: EditorView, position = view.state.selection.main.head) {
  let node = syntaxTree(view.state).resolveInner(position, -1);
  while (node.name !== 'FencedCode' && node.parent !== null) node = node.parent;
  return node.name === 'FencedCode' ? fences(node, view.state) : undefined;
}

type Code = NonNullable<ReturnType<typeof fences>>;

function bodyPrefix(code: Code, state: EditorState) {
  let prefix = state.sliceDoc(code.first.from, code.opening.from);
  let nested = false;
  for (let parent = code.node.parent; parent !== null; parent = parent.parent) {
    if (parent.name === 'ListItem' || parent.name === 'Blockquote') nested = true;
    const mark = parent.name === 'ListItem' ? parent.getChild('ListMark') : null;
    if (mark !== null && mark.from >= code.first.from && mark.to <= code.opening.from) {
      const start = mark.from - code.first.from;
      prefix = prefix.slice(0, start) + ' '.repeat(mark.to - mark.from) + prefix.slice(mark.to - code.first.from);
    }
  }
  const text = code.node.getChild('CodeText');
  if (text !== null) {
    const actualPrefix = state.sliceDoc(state.doc.lineAt(text.from).from, text.from);
    if (actualPrefix.length > 0) return actualPrefix;
  }
  return nested ? prefix : '';
}

function move(view: EditorView, anchor: number) {
  view.dispatch({ selection: { anchor }, scrollIntoView: true });
  view.focus();
  return true;
}

function edit(view: EditorView, from: number, to: number, insert: string, anchor = from + insert.length) {
  view.dispatch({ changes: { from, to, insert }, selection: { anchor }, scrollIntoView: true,
    annotations: isolateHistory.of('full'), userEvent: 'input.code' });
  return true;
}

function enterBody(view: EditorView, code: Code) {
  const prefix = bodyPrefix(code, view.state);
  if (code.last?.number === code.first.number + 1) {
    return view.state.readOnly ? false : edit(view, code.last.from, code.last.from, prefix + '\n', code.last.from + prefix.length);
  }
  return move(view, Math.min(view.state.doc.line(code.first.number + 1).to, code.first.to + 1 + prefix.length));
}

function exitCode(view: EditorView, createParagraph = true) {
  const code = currentCode(view);
  if (code?.last === undefined) return false;
  const prefix = bodyPrefix(code, view.state);
  if (code.last.number < view.state.doc.lines) {
    const next = view.state.doc.line(code.last.number + 1);
    return move(view, next.from + (next.text.startsWith(prefix) ? prefix.length : 0));
  }
  if (!createParagraph) return move(view, view.state.doc.line(Math.max(code.first.number + 1, code.last.number - 1)).to);
  return view.state.readOnly ? false : edit(view, code.last.to, code.last.to, '\n' + prefix);
}

class LanguageLabel extends WidgetType {
  constructor(private readonly from: number, private readonly language: string) { super(); }
  eq(other: LanguageLabel) { return this.from === other.from && this.language === other.language; }
  toDOM(view: EditorView) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'cm-mvp-code-language';
    button.textContent = this.language || '纯文本';
    button.setAttribute('aria-label', `代码语言：${this.language || '纯文本'}，点击修改`);
    button.title = '修改代码语言；代码中按 ⌘Enter 返回正文';
    button.disabled = view.state.readOnly;
    button.addEventListener('click', () => {
      if (view.compositionStarted || view.state.readOnly) return;
      const node = syntaxTree(view.state).resolveInner(this.from + 1);
      const code = fences(node.name === 'CodeMark' && node.parent !== null ? node.parent : node, view.state);
      if (code === undefined) return;
      const from = code.info?.from ?? code.opening.to;
      view.dispatch({ selection: EditorSelection.single(from, code.info?.to ?? from), effects: editLanguage.of(code.opening.from) });
      view.focus();
    });
    return button;
  }
}

export function codeDecorations(node: SyntaxNode, view: EditorView, revealSearch: boolean) {
  const { state } = view;
  const code = fences(node, state);
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  // 未闭合的原始代码块保留源码，避免隐藏文档余下内容的边界。
  if (code?.last === undefined || code.closing === undefined) return { decorations, atoms };
  const selected = (from: number, to: number) => revealSearch && state.selection.ranges.some(range => !range.empty && range.from < to && range.to > from);
  const languageEditing = state.field(editingCodeLanguage, false) === code.opening.from;
  const revealOpening = languageEditing || selected(code.opening.from, code.first.to);
  const revealClosing = selected(code.closing.from, code.last.to);
  const first = Math.max(code.first.number, state.doc.lineAt(view.viewport.from).number);
  const last = Math.min(code.last.number, state.doc.lineAt(view.viewport.to).number);
  for (let number = first; number <= last; number++) {
    const classes = ['cm-mvp-code'];
    if (number === code.first.number) classes.push('cm-mvp-code-header');
    if (number === code.last.number && !revealClosing) classes.push('cm-mvp-code-footer');
    decorations.push(Decoration.line({ class: classes.join(' ') }).range(state.doc.line(number).from));
  }
  if (!revealOpening) {
    const range = Decoration.replace({ widget: new LanguageLabel(code.opening.from, code.info === null ? '' : state.sliceDoc(code.info.from, code.info.to)) }).range(code.opening.from, code.first.to);
    decorations.push(range);
    atoms.push(range);
  }
  if (!revealClosing) {
    const range = Decoration.replace({}).range(code.closing.from, code.last.to);
    decorations.push(range);
    atoms.push(range);
  }
  return { decorations, atoms };
}

function codeEnter(view: EditorView) {
  const code = currentCode(view);
  if (code === undefined) return false;
  const { state } = view;
  const selection = state.selection.main;
  const line = state.doc.lineAt(selection.head);
  if (line.number === code.first.number) {
    if (code.last !== undefined && selection.from >= code.first.from && selection.to <= code.first.to) return enterBody(view, code);
    if (!selection.empty) return false;
    if (selection.head !== line.to) return false;
    const prefix = bodyPrefix(code, state);
    const mark = state.sliceDoc(code.opening.from, code.opening.to);
    return edit(view, line.to, line.to, '\n' + prefix + '\n' + prefix + mark, line.to + 1 + prefix.length);
  }
  if (code.last === undefined) return false;
  if (!selection.empty && (selection.from <= code.first.to || selection.to >= code.last.from)) return false;
  if (line.number === code.last.number) return exitCode(view);
  const prefix = bodyPrefix(code, state);
  const startLine = state.doc.lineAt(selection.from);
  const indentation = /^[ \t]*/.exec(startLine.text.slice(prefix.length))?.[0] ?? '';
  return edit(view, selection.from, selection.to, '\n' + prefix + indentation);
}

function codeBackspace(view: EditorView) {
  const code = currentCode(view);
  const selection = view.state.selection.main;
  if (code?.last === undefined || !selection.empty) return false;
  const prefix = bodyPrefix(code, view.state);
  const start = code.first.to + 1 + prefix.length;
  if (selection.head !== start) return false;
  if (code.last.number === code.first.number + 2 && !/\S/.test(view.state.doc.line(code.first.number + 1).text.slice(prefix.length))) {
    return edit(view, code.first.from, code.last.to, view.state.sliceDoc(code.first.from, code.opening.from));
  }
  return true; // 正文起点不删除开围栏；完整源码可在源码模式编辑。
}

function indentCode(view: EditorView, outdent: boolean) {
  const code = currentCode(view);
  if (code?.last === undefined) return false;
  const { state } = view;
  const selection = state.selection.main;
  const first = state.doc.lineAt(selection.from).number;
  const last = state.doc.lineAt(selection.empty ? selection.to : selection.to - 1).number;
  if (first <= code.first.number || last >= code.last.number) return false;
  const prefix = bodyPrefix(code, state);
  const changes = [];
  for (let number = first; number <= last; number++) {
    const line = state.doc.line(number);
    const start = line.from + (line.text.startsWith(prefix) ? prefix.length : 0);
    const whitespace = /^[ \t]*/.exec(state.sliceDoc(start, line.to))?.[0] ?? '';
    const unit = whitespace.includes('\t') ? '\t' : state.facet(indentUnit);
    if (outdent) {
      const length = whitespace.startsWith('\t') ? 1 : Math.min(whitespace.length, unit.length);
      if (length > 0) changes.push({ from: start, to: start + length, insert: '' });
    } else {
      changes.push({ from: selection.empty ? selection.head : start, insert: unit });
    }
  }
  if (changes.length > 0) {
    const changeSet = state.changes(changes);
    view.dispatch({ changes: changeSet, selection: state.selection.map(changeSet, 1),
      annotations: isolateHistory.of('full'), userEvent: 'input.code', scrollIntoView: true });
  }
  return true;
}

function beforeCode(view: EditorView, code: Code) {
  if (code.first.number === 1) return move(view, code.first.to + 1 + bodyPrefix(code, view.state).length);
  const previous = view.state.doc.line(code.first.number - 1);
  const previousCode = currentCode(view, previous.to);
  if (previousCode?.last?.number === previous.number && previous.number > previousCode.first.number + 1) {
    return move(view, view.state.doc.line(previous.number - 1).to);
  }
  return move(view, previous.to);
}

export const codeBindings: KeyBinding[] = [
  { key: 'Enter', run: codeEnter },
  { key: 'Mod-Enter', run: exitCode },
  { key: 'Escape', run: view => {
    const code = currentCode(view);
    if (code === undefined) return false;
    if (view.state.field(editingCodeLanguage) === code.opening.from) {
      if (code.last?.number === code.first.number + 1) {
        view.dispatch({ effects: editLanguage.of(null) });
        view.contentDOM.querySelector<HTMLButtonElement>('.cm-mvp-code-language')?.focus();
        return true;
      }
      return enterBody(view, code);
    }
    return view.state.selection.main.empty ? exitCode(view, false) : false;
  } },
  { key: 'Backspace', run: codeBackspace },
  { key: 'Delete', run: view => {
    const code = currentCode(view);
    return code?.last !== undefined && view.state.selection.main.empty && view.state.selection.main.head === code.last.from - 1;
  } },
  { key: 'ArrowDown', run: view => {
    const code = currentCode(view);
    if (code?.last === undefined || !view.state.selection.main.empty || view.state.doc.lineAt(view.state.selection.main.head).number !== code.last.number - 1) return false;
    cursorLineDown(view);
    if (view.state.doc.lineAt(view.state.selection.main.head).number === code.last.number) exitCode(view, false);
    return true;
  } },
  { key: 'ArrowUp', run: view => {
    const code = currentCode(view);
    if (code?.last === undefined || !view.state.selection.main.empty || view.state.doc.lineAt(view.state.selection.main.head).number !== code.first.number + 1) return false;
    cursorLineUp(view);
    if (view.state.doc.lineAt(view.state.selection.main.head).number === code.first.number) beforeCode(view, code);
    return true;
  } },
  { key: 'ArrowLeft', run: view => {
    const code = currentCode(view);
    return code?.last !== undefined && view.state.selection.main.empty
      && view.state.selection.main.head === code.first.to + 1 + bodyPrefix(code, view.state).length ? beforeCode(view, code) : false;
  } },
  { key: 'ArrowRight', run: view => {
    const code = currentCode(view);
    return code?.last !== undefined && view.state.selection.main.empty
      && view.state.selection.main.head === code.last.from - 1 ? exitCode(view, false) : false;
  } },
  { key: 'Tab', run: view => indentCode(view, false), shift: view => indentCode(view, true) },
];

export const codeTheme = EditorView.theme({
  '.cm-mvp-code': { backgroundColor: '#f4f5f7', fontFamily: 'Menlo, monospace', color: '#30343b', paddingLeft: '12px', paddingRight: '12px' },
  '.cm-mvp-code-header': { borderTopLeftRadius: '6px', borderTopRightRadius: '6px', paddingTop: '6px', fontSize: '13px' },
  '.cm-mvp-code-footer': { height: '6px', minHeight: '0', lineHeight: '0', fontSize: '0', borderBottomLeftRadius: '6px', borderBottomRightRadius: '6px' },
  '.cm-mvp-code-language': { appearance: 'none', border: '0', backgroundColor: 'transparent', color: '#5f6368', font: 'inherit', padding: '0 0 4px', cursor: 'pointer' },
});
