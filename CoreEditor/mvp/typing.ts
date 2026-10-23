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
