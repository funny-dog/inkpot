import { EditorState, Range } from '@codemirror/state';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { Decoration, EditorView, ViewPlugin, WidgetType } from '@codemirror/view';
import { SyntaxNode } from '@lezer/common';

export function selectionTouches(state: EditorState, from: number, to: number, includeCursor: boolean) {
  return state.selection.ranges.some(range => range.empty
    ? includeCursor && from < range.head && range.head < to : range.from < to && range.to > from);
}

class Rule extends WidgetType {
  eq() { return true; }
  toDOM() {
    const element = document.createElement('span');
    element.className = 'cm-inkpot-rule';
    element.setAttribute('role', 'separator');
    return element;
  }
}

export function basicDecorations(node: SyntaxNode, view: EditorView, searchSelection: boolean) {
  const { state } = view;
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  const editing = selectionTouches(state, node.from, node.to, true);
  function hide(from: number, to: number) {
    if (from < to) decorations.push(Decoration.mark({ class: 'cm-inkpot-hidden-inline' }).range(from, to));
  }
  if (node.name === 'InlineCode') {
    decorations.push(Decoration.mark({ class: 'cm-inkpot-inline-code' }).range(node.from, node.to));
    if (!editing) for (const mark of node.getChildren('CodeMark')) hide(mark.from, mark.to);
  } else if (node.name === 'Link' || node.name === 'Autolink') {
    decorations.push(Decoration.mark({ class: 'cm-inkpot-link', attributes: { title: '⌘单击或 ⌘Enter 打开链接', role: 'link' } }).range(node.from, node.to));
    const marks = node.getChildren('LinkMark');
    if (!editing && marks.length >= 2) {
      hide(marks[0].from, marks[0].to);
      hide(marks[1].from, node.to);
    }
  } else if (/^SetextHeading[12]$/.test(node.name)) {
    const mark = node.getChild('HeaderMark');
    if (mark === null) return { decorations, atoms };
    const last = state.doc.lineAt(mark.from).number;
    for (let line = state.doc.lineAt(node.from).number; line < last; line++) {
      decorations.push(Decoration.line({ class: `cm-inkpot-heading${node.name.at(-1)}` }).range(state.doc.line(line).from));
    }
    if (!(searchSelection && selectionTouches(state, mark.from, mark.to, false))) {
      hide(mark.from, mark.to);
      decorations.push(Decoration.line({ class: 'cm-inkpot-setext-mark' }).range(state.doc.line(last).from));
    }
  } else if (node.name === 'HorizontalRule' && !(searchSelection && selectionTouches(state, node.from, node.to, false))) {
    const replacement = Decoration.replace({ widget: new Rule() }).range(node.from, node.to);
    decorations.push(replacement);
    atoms.push(replacement);
  }
  return { decorations, atoms };
}

function unescape(text: string) {
  const decoder = document.createElement('textarea');
  decoder.innerHTML = text.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g, '$1');
  return decoder.value;
}

export function linkDestination(node: SyntaxNode, state: EditorState): string | undefined {
  const url = node.getChild('URL');
  if (url !== null) {
    const value = state.sliceDoc(url.from, url.to).replace(/^<|>$/g, '');
    return node.name === 'Autolink' && !value.includes(':') && value.includes('@') ? `mailto:${value}` : unescape(value);
  }
  const label = node.getChild('LinkLabel');
  const normalize = (text: string) => unescape(text).trim().replace(/\s+/g, ' ').toLowerCase();
  const text = label === null || state.sliceDoc(label.from, label.to) === '[]'
    ? state.sliceDoc(node.from + (node.name === 'Image' ? 2 : 1), node.getChildren('LinkMark')[1]?.from ?? node.to - 1)
    : state.sliceDoc(label.from + 1, label.to - 1);
  const key = normalize(text);
  let destination: string | undefined;
  const tree = ensureSyntaxTree(state, state.doc.length, 10) ?? syntaxTree(state);
  tree.iterate({ enter(reference) {
    if (destination !== undefined || reference.name !== 'LinkReference') return;
    const name = reference.node.getChild('LinkLabel');
    const target = reference.node.getChild('URL');
    if (name !== null && target !== null && normalize(state.sliceDoc(name.from + 1, name.to - 1)) === key) {
      destination = unescape(state.sliceDoc(target.from, target.to).replace(/^<|>$/g, ''));
    }
    return false;
  } });
  return destination;
}

export function linkAt(view: EditorView, position: number) {
  let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(position, 1);
  while (node !== null && !['Link', 'Autolink', 'Image', 'Document'].includes(node.name)) node = node.parent;
  return node !== null && ['Link', 'Autolink'].includes(node.name) ? linkDestination(node, view.state) : undefined;
}

export function linkNavigation(open: (destination: string) => void) {
  return ViewPlugin.define(() => ({}), { eventHandlers: {
    mousedown(event, view) {
      if (!event.metaKey || event.button !== 0 || view.compositionStarted) return false;
      const position = view.posAtCoords({ x: event.clientX, y: event.clientY });
      const destination = position === null ? undefined : linkAt(view, position);
      if (destination === undefined) return false;
      event.preventDefault();
      open(destination);
      return true;
    },
  } });
}
