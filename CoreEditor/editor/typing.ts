import { Compartment, EditorSelection, Facet, Transaction } from '@codemirror/state';
import { deleteMarkupBackward, insertNewlineContinueMarkupCommand } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { EditorView, KeyBinding } from '@codemirror/view';

const continueMarkup = insertNewlineContinueMarkupCommand({ nonTightLists: false });

function editMarkup(view: EditorView, enter: boolean) {
  const { state } = view;
  if (view.compositionStarted || state.readOnly) return true;
  const selection = state.selection.main;
  if (!selection.empty || state.selection.ranges.length !== 1) return false;
  const line = state.doc.lineAt(selection.head);
  const syntaxPosition = Math.min(selection.head, line.from + line.text.trimEnd().length);
  let context = syntaxTree(state).resolveInner(syntaxPosition, -1);
  while (!['ListItem', 'Blockquote', 'FencedCode', 'CodeBlock', 'HTMLBlock', 'Document'].includes(context.name) && context.parent !== null) {
    context = context.parent;
  }
  if (['FencedCode', 'CodeBlock', 'HTMLBlock'].includes(context.name)) return false;

  const lastQuote = context.getChildren('QuoteMark').filter(mark => mark.from >= line.from && mark.to <= selection.head).at(-1);
  const emptyQuote = lastQuote !== undefined && !/\S/.test(state.sliceDoc(lastQuote.to, line.to));
  const changes: { from: number; to: number; insert: string }[] = [];
  let handled = true;
  if (enter && emptyQuote) {
    changes.push({ from: lastQuote.from, to: line.to, insert: '' });
  } else {
    handled = (enter ? continueMarkup : deleteMarkupBackward)({ state, dispatch: transaction => {
      transaction.changes.iterChanges((from, to, _newFrom, _newTo, inserted) => {
        if (from <= line.to) changes.push({ from, to, insert: inserted.toString() });
      });
    } });
  }
  // 仅使用当前行的结构编辑，不自动重编号后续条目。
  if (!handled || changes.length !== 1 || changes.some(change => change.from < line.from || change.to > line.to)) return false;
  const change = changes[0];

  // 回车只插入新行，保留光标前原有空格（包括 Markdown 硬换行的两个空格）。
  if (enter && change.insert.startsWith('\n') && change.to === selection.head) {
    change.from = selection.head;
    // 原列表含空行时，也保持一次回车只新增一行。
    change.insert = change.insert.replace(/^\n[ \t>]*\n/, '\n');
  }
  view.dispatch(state.update({
    changes: change,
    selection: { anchor: change.from + change.insert.length },
    annotations: isolateHistory.of('full'),
    userEvent: enter ? 'input.structure' : 'delete.structure',
    scrollIntoView: true,
  }));
  return true;
}

export const typingBindings: KeyBinding[] = [
  { key: 'Enter', run: view => editMarkup(view, true) },
  { key: 'Backspace', run: view => editMarkup(view, false) },
];

const pairs: Readonly<Partial<Record<string, string>>> = { '(': ')', '[': ']', '"': '"', '`': '`', '*': '*' };
export type PairingPreferences = { brackets: boolean; markdown: boolean };
export const pairingPreferences = Facet.define<PairingPreferences, PairingPreferences>({
  combine: values => values.at(-1) ?? { brackets: true, markdown: true },
});
export const pairingCompartment = new Compartment();

export const autoPairs = EditorView.inputHandler.of((view, from, to, text, insert) => {
  const { state } = view;
  const selection = state.selection.main;
  const enabled = state.facet(pairingPreferences);
  if (['*', '`'].includes(text) ? !enabled.markdown : !enabled.brackets) return false;
  if (view.compositionStarted || state.readOnly || !state.facet(EditorView.editable)
    || text.length !== 1 || state.selection.ranges.length !== 1
    || from !== selection.from || to !== selection.to || insert().annotation(Transaction.userEvent) !== 'input.type') return false;
  const before = state.sliceDoc(state.doc.lineAt(from).from, from);
  if ((/\\+$/.exec(before)?.[0].length ?? 0) % 2 !== 0) return false;
  const next = state.sliceDoc(to, to + 1);
  if (selection.empty && [')', ']', '"', '`', '*'].includes(text) && next === text) {
    // 连续星号和反引号仍可扩展为粗体或围栏；正文后的闭合符直接越过。
    if (!['*', '`'].includes(text) || !/(?:^|\s)(?:\*+|`+)$/.test(before)) {
      view.dispatch({ selection: { anchor: to + 1 }, userEvent: 'select' });
      return true;
    }
  }
  const close = pairs[text];
  if (close === undefined || (selection.empty && /[\p{L}\p{N}_]/u.test(next))) return false;
  view.dispatch(state.update({
    changes: selection.empty ? { from, insert: text + close }
      : [{ from, insert: text }, { from: to, insert: close }],
    selection: EditorSelection.single(selection.anchor + 1, selection.head + 1),
    userEvent: 'input.type', scrollIntoView: true,
  }));
  return true;
});
