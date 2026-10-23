import { EditorSelection, EditorState, StateField, Range } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory, redo, undo } from '@codemirror/commands';
import { Command, Decoration, DecorationSet, EditorView, keymap, WidgetType } from '@codemirror/view';
import { SyntaxNode } from '@lezer/common';
import { linkDestination } from './basic';
import { isComposing, sourceMode } from './mode';
import { Cell, readTable, serializeTable, Table } from './table-model';

function tableAt(state: EditorState, position = state.selection.main.head): Table | undefined {
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(position, 1);
  while (node !== null && node.name !== 'Table') node = node.parent;
  // shortcut: 嵌套列表和引用中的表格先保留源码，支持时需同时维护每行容器前缀。
  return node?.parent?.name === 'Document' ? readTable(state, node.from, node.to) : undefined;
}

export function tableContext(view: EditorView) {
  if (view.state.field(sourceMode) || isComposing(view) || view.state.readOnly || !view.state.facet(EditorView.editable)) return;
  const focused = view.dom.ownerDocument.activeElement;
  const input = focused instanceof HTMLInputElement && focused.matches('.cm-mvp-table-input') ? focused : undefined;
  const wrapper = input?.closest<HTMLElement>('.cm-mvp-table');
  const table = tableAt(view.state, wrapper == null ? undefined : Number(wrapper.dataset.from) + 1);
  if (table === undefined) return;
  if (input !== undefined) return { table, row: Number(input.dataset.row), column: Number(input.dataset.column) };
  const line = view.state.doc.lineAt(view.state.selection.main.head).number - view.state.doc.lineAt(table.from).number;
  const row = Math.min(Math.max(0, line - (line > 0 ? 1 : 0)), table.rows.length - 1);
  const cells = table.rows[row];
  const column = Math.min(cells.findIndex(cell => view.state.selection.main.head <= cell.to), table.alignments.length - 1);
  return { table, row, column: column < 0 ? table.alignments.length - 1 : column };
}

export function syncTableSelection(view: EditorView) {
  const input = view.dom.ownerDocument.activeElement;
  if (!(input instanceof HTMLInputElement) || !input.matches('.cm-mvp-table-input') || !view.dom.contains(input) || isComposing(view)) return;
  const from = Number(input.dataset.from), to = Number(input.dataset.to);
  const start = Math.min(to, from + (input.selectionStart ?? 0)), end = Math.min(to, from + (input.selectionEnd ?? 0));
  view.dispatch({ selection: input.selectionDirection === 'backward' ? EditorSelection.single(end, start) : EditorSelection.single(start, end) });
}

function normalizeCell(value: string) {
  return value.replace(/[\r\n\t]+/g, ' ').replace(/\\*\|/g, match => match.length % 2 === 1 ? '\\' + match : match);
}

function cellPreview(state: EditorState, cell: Cell | undefined): DocumentFragment {
  const result = document.createDocumentFragment();
  if (cell === undefined) return result;
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(cell.from, 1);
  while (node !== null && node.name !== 'TableCell') node = node.parent;
  if (node === null) { result.append(cell.text); return result; }
  function append(parent: Node, node: SyntaxNode) {
    if (['EmphasisMark', 'CodeMark', 'LinkMark'].includes(node.name)) return;
    if (['InlineCode', 'Image', 'HTMLTag', 'Escape', 'Entity'].includes(node.name)) {
      const code = node.name === 'InlineCode';
      const element = document.createElement(code ? 'code' : 'span');
      if (code) element.className = 'cm-mvp-inline-code';
      const marks = node.getChildren('CodeMark');
      element.textContent = code ? state.sliceDoc(marks[0].to, marks[1].from) : state.sliceDoc(node.from, node.to);
      parent.appendChild(element);
      return;
    }
    const element = document.createElement(node.name === 'StrongEmphasis' ? 'strong' : node.name === 'Emphasis' ? 'em' : 'span');
    const link = node.name === 'Link' || node.name === 'Autolink';
    if (link) {
      element.className = 'cm-mvp-link';
      element.setAttribute('role', 'link');
      const destination = linkDestination(node, state);
      if (destination !== undefined) element.dataset.destination = destination;
      element.title = '⌘单击打开链接';
    }
    const last = link ? node.getChildren('LinkMark')[1]?.from ?? node.to : node.to;
    let from = node.from;
    for (let child = node.firstChild; child !== null && child.from < last; child = child.nextSibling) {
      element.append(state.sliceDoc(from, child.from));
      append(element, child);
      from = child.to;
    }
    element.append(state.sliceDoc(from, last));
    parent.appendChild(element);
  }
  append(result, node);
  return result;
}

class TableWidget extends WidgetType {
  constructor(readonly table: Table, readonly readOnly: boolean) { super(); }
  eq(other: TableWidget) { return this.readOnly === other.readOnly && JSON.stringify(this.table) === JSON.stringify(other.table); }

  toDOM(view: EditorView) {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-mvp-table';
    const table = wrapper.appendChild(document.createElement('table'));
    table.setAttribute('aria-label', 'Markdown 表格');
    table.style.minWidth = `${this.table.alignments.length * 100}px`;
    this.table.rows.forEach((_cells, row) => {
      const tr = table.insertRow();
      for (let column = 0; column < this.table.alignments.length; column++) {
        const td = tr.appendChild(document.createElement(row === 0 ? 'th' : 'td'));
        if (row === 0) td.setAttribute('scope', 'col');
        const preview = td.appendChild(document.createElement('div'));
        preview.className = 'cm-mvp-table-preview';
        const input = td.appendChild(document.createElement('input'));
        input.className = 'cm-mvp-table-input';
        input.setAttribute('aria-label', `第 ${row + 1} 行，第 ${column + 1} 列`);
        input.dataset.row = String(row);
        input.dataset.column = String(column);
        input.spellcheck = false;
        preview.addEventListener('mousedown', event => {
          const link = (event.target as HTMLElement).closest<HTMLElement>('[data-destination]');
          if (event.metaKey && link?.dataset.destination !== undefined) {
            event.preventDefault();
            view.dom.dispatchEvent(new CustomEvent('kernmark-open-link', { bubbles: true, detail: link.dataset.destination }));
          } else if (event.button === 0 && !view.state.readOnly && view.state.facet(EditorView.editable)) {
            event.preventDefault(); input.focus(); input.select();
          }
        });
        input.addEventListener('focus', () => { syncTableSelection(view); });
        input.addEventListener('select', () => { if (input.isConnected && input.ownerDocument.activeElement === input && !isComposing(view)) syncTableSelection(view); });
        input.addEventListener('input', event => { if (!(event as InputEvent).isComposing && !input.hasAttribute('data-table-composing')) this.edit(view, input); });
        input.addEventListener('compositionstart', () => { input.setAttribute('data-table-composing', ''); });
        input.addEventListener('compositionend', () => { input.removeAttribute('data-table-composing'); this.edit(view, input); });
        input.addEventListener('keydown', event => {
          if (event.isComposing || isComposing(view)) return;
          if (event.metaKey && event.key.toLowerCase() === 'z') {
            event.preventDefault(); (event.shiftKey ? redo : undo)(view);
          } else if (event.metaKey && event.key === 'Enter') {
            event.preventDefault(); leaveTable(view, true);
          } else if (['Tab', 'Enter', 'Escape'].includes(event.key)) {
            event.preventDefault();
            const inputs = [...wrapper.querySelectorAll<HTMLInputElement>('input')];
            const step = event.key === 'Enter' ? this.table.alignments.length : 1;
            const index = inputs.indexOf(input) + (event.shiftKey ? -step : step);
            if (event.key !== 'Escape' && index >= 0 && index < inputs.length) { inputs[index].focus(); inputs[index].select(); } else this.exit(view, event.shiftKey);
          }
        });
      }
    });
    const hint = wrapper.appendChild(document.createElement('div'));
    hint.className = 'cm-mvp-table-hint';
    hint.textContent = 'Tab 切换单元格 · Enter 下一行 · ⌘Enter 返回正文 · 格式 → 表格增删行列';
    this.updateDOM(wrapper, view);
    return wrapper;
  }

  updateDOM(wrapper: HTMLElement, view: EditorView) {
    if (wrapper.querySelectorAll('tr').length !== this.table.rows.length || wrapper.querySelectorAll('tr:first-child input').length !== this.table.alignments.length) return false;
    wrapper.dataset.from = String(this.table.from);
    wrapper.dataset.to = String(this.table.to);
    for (const input of wrapper.querySelectorAll<HTMLInputElement>('input')) {
      const row = Number(input.dataset.row), column = Number(input.dataset.column);
      const cell = this.table.rows[row].at(column);
      const line = view.state.doc.line(view.state.doc.lineAt(this.table.from).number + row + (row > 0 ? 1 : 0));
      if (!input.hasAttribute('data-table-commit')) {
        input.dataset.from = String(cell?.from ?? line.to);
        input.dataset.to = String(cell?.to ?? line.to);
      }
      input.disabled = this.readOnly;
      if (!input.hasAttribute('data-table-composing') && !input.hasAttribute('data-table-commit') && input.value !== (cell?.text ?? '')) input.value = cell?.text ?? '';
      const td = input.parentElement;
      if (td === null) continue;
      const alignment = this.table.alignments[column];
      td.style.textAlign = alignment.startsWith(':') ? (alignment.endsWith(':') ? 'center' : 'left') : alignment.endsWith(':') ? 'right' : 'left';
      td.querySelector('.cm-mvp-table-preview')?.replaceChildren(cellPreview(view.state, cell));
    }
    return true;
  }

  private edit(view: EditorView, input: HTMLInputElement) {
    if (view.state.readOnly || !view.state.facet(EditorView.editable) || !input.isConnected) return;
    const wrapper = input.closest<HTMLElement>('.cm-mvp-table');
    if (wrapper === null) return;
    const table = readTable(view.state, Number(wrapper.dataset.from), Number(wrapper.dataset.to));
    const row = Number(input.dataset.row), column = Number(input.dataset.column);
    const value = normalizeCell(input.value);
    const cell = table.rows[row].at(column);
    if (view.state.sliceDoc(Number(input.dataset.from), Number(input.dataset.to)) === value) return;
    const from = Number(input.dataset.from);
    let insert = value;
    let valueOffset = 0;
    if (cell === undefined) {
      const line = view.state.doc.lineAt(from);
      const trailing = /(?<!\\)\|\s*$/.test(line.text);
      const prefix = (trailing ? ' ' : ' | ') + Array.from({ length: column - table.rows[row].length }, () => ' | ').join('');
      valueOffset = prefix.length;
      insert = prefix + value + (trailing ? ' |' : '');
    }
    const caret = normalizeCell(input.value.slice(0, input.selectionEnd ?? input.value.length)).length;
    const to = Number(input.dataset.to);
    // 编辑期间将新输入的首尾空格保留在当前范围内，不能当作表格排版空格裁掉。
    input.setAttribute('data-table-commit', '');
    input.dataset.from = String(from + valueOffset);
    input.dataset.to = String(from + valueOffset + value.length);
    input.value = value;
    try {
      view.dispatch({ changes: { from, to, insert }, selection: { anchor: from + valueOffset + caret }, userEvent: 'input.type' });
    } finally { input.removeAttribute('data-table-commit'); }
    // DOM 可能在补齐缺失单元格时重建，只恢复属于当前文档的目标。
    const target = view.dom.querySelector<HTMLInputElement>(`.cm-mvp-table[data-from="${table.from}"] input[data-row="${row}"][data-column="${column}"]`);
    target?.focus(); target?.setSelectionRange(caret, caret);
  }

  private exit(view: EditorView, before: boolean) {
    const table = tableAt(view.state);
    if (table === undefined) return;
    const position = before ? Math.max(0, table.from - 1) : Math.min(view.state.doc.length, table.to + 1);
    view.dispatch({ selection: { anchor: position }, scrollIntoView: true });
    view.focus();
  }
  ignoreEvent() { return true; }
}

const searchSelection = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.isUserEvent('select.search') ? true : transaction.selection !== undefined || transaction.docChanged ? false : value,
});
function decorations(state: EditorState) {
  if (state.field(sourceMode)) return Decoration.none;
  const ranges: Range<Decoration>[] = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== 'Table' || node.node.parent?.name !== 'Document') return;
    const selection = state.selection.main;
    if (!(state.field(searchSelection) && selection.from < node.to && selection.to > node.from)) {
      const table = readTable(state, node.from, node.to);
      ranges.push(Decoration.replace({ block: true, widget: new TableWidget(table, state.readOnly || !state.facet(EditorView.editable)) }).range(table.from, table.to));
    }
    return false;
  } });
  return Decoration.set(ranges, true);
}
const tables = StateField.define<DecorationSet>({
  create: decorations,
  update: (value, transaction) => transaction.docChanged || transaction.selection !== undefined || transaction.reconfigured
    || transaction.startState.field(sourceMode) !== transaction.state.field(sourceMode)
    || syntaxTree(transaction.startState) !== syntaxTree(transaction.state) ? decorations(transaction.state) : value,
  provide: field => EditorView.decorations.from(field),
});

export function canTableCommand(name: string, view: EditorView) {
  if (isComposing(view) || view.state.readOnly || !view.state.facet(EditorView.editable)) return false;
  const context = tableContext(view);
  if (name === 'insertTable') {
    let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(view.state.selection.main.head, 1);
    while (node !== null) {
      if (['Table', 'FencedCode', 'CodeBlock', 'HTMLBlock', 'ListItem', 'Blockquote'].includes(node.name)) return false;
      node = node.parent;
    }
    return true;
  }
  return context !== undefined && (name !== 'tableDeleteRow' || context.row > 0) && (name !== 'tableDeleteColumn' || context.table.alignments.length > 1);
}

export const tableCommands: Readonly<Record<string, Command>> = Object.fromEntries([
  'insertTable', 'tableRowAbove', 'tableRowBelow', 'tableColumnBefore', 'tableColumnAfter', 'tableDeleteRow', 'tableDeleteColumn',
  'tableAlignLeft', 'tableAlignCenter', 'tableAlignRight',
].map(name => [name, (view: EditorView) => {
  if (!canTableCommand(name, view)) return false;
  const { state } = view;
  let change: { from: number; to: number; insert: string };
  const context = tableContext(view);
  let targetRow = 1, targetColumn = 0;
  if (name === 'insertTable') {
    const { from, to } = state.selection.main;
    const before = from > 0 ? '\n\n' : '';
    change = { from, to, insert: before + '| 列 1 | 列 2 |\n| --- | --- |\n|  |  |\n|  |  |\n\n' };
  } else {
    if (context === undefined) return false;
    const { table, row, column } = context;
    const rows = table.rows.map(cells => cells.map(cell => cell.text));
    const alignments = [...table.alignments];
    targetRow = row; targetColumn = column;
    if (name === 'tableRowAbove' || name === 'tableRowBelow') {
      targetRow = Math.max(1, row + (name === 'tableRowBelow' ? 1 : 0));
      rows.splice(targetRow, 0, alignments.map(() => ''));
    } else if (name === 'tableDeleteRow') {
      rows.splice(row, 1); targetRow = Math.min(row, rows.length - 1);
    } else if (name === 'tableColumnBefore' || name === 'tableColumnAfter') {
      targetColumn = column + (name === 'tableColumnAfter' ? 1 : 0);
      rows.forEach(cells => { while (cells.length < targetColumn) cells.push(''); cells.splice(targetColumn, 0, ''); });
      alignments.splice(targetColumn, 0, '---');
    } else if (name === 'tableDeleteColumn') {
      rows.forEach(cells => cells.splice(column, 1)); alignments.splice(column, 1);
      targetColumn = Math.min(column, alignments.length - 1);
    } else {
      alignments[column] = name === 'tableAlignCenter' ? ':---:' : name === 'tableAlignRight' ? '---:' : ':---';
    }
    change = { from: table.from, to: table.to, insert: serializeTable(rows, alignments, '\n', table.prefix) };
  }
  view.dispatch(state.update({ changes: change, selection: { anchor: change.from }, annotations: isolateHistory.of('full'), userEvent: 'input.table', scrollIntoView: true }));
  const wrapper = [...view.dom.querySelectorAll<HTMLElement>('.cm-mvp-table')].find(element => Number(element.dataset.from) >= change.from);
  const input = wrapper?.querySelector<HTMLInputElement>(`input[data-row="${targetRow}"][data-column="${targetColumn}"]`);
  if (input !== null && input !== undefined) { input.focus(); input.select(); } else view.focus();
  return true;
}]));

function leaveTable(view: EditorView, append: boolean) {
  const context = tableContext(view);
  if (context === undefined) return false;
  const position = context.table.to + 1;
  if (position > view.state.doc.length && append) {
    view.dispatch({ changes: { from: context.table.to, insert: '\n\n' }, selection: { anchor: context.table.to + 2 }, annotations: isolateHistory.of('full'), userEvent: 'input.table' });
  } else view.dispatch({ selection: { anchor: Math.min(position, view.state.doc.length) }, scrollIntoView: true });
  view.focus(); return true;
}

export const tableEditing = [
  searchSelection, tables,
  EditorView.atomicRanges.of(view => view.state.field(tables)),
  keymap.of([{ key: 'Mod-Enter', run: view => leaveTable(view, true) }, { key: 'Enter', run: view => leaveTable(view, true) }]),
  EditorView.theme({
    '.cm-mvp-table': { overflowX: 'auto', margin: '12px 0' },
    '.cm-mvp-table table': { borderCollapse: 'collapse', width: '100%', tableLayout: 'fixed' },
    '.cm-mvp-table th, .cm-mvp-table td': { border: '1px solid #c6cbd1', padding: '0', position: 'relative', verticalAlign: 'top' },
    '.cm-mvp-table th': { background: '#f4f5f6' },
    '.cm-mvp-table-preview': { padding: '8px 10px', minHeight: '1.6em', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
    '.cm-mvp-table-input': { display: 'block', boxSizing: 'border-box', width: '100%', padding: '8px 10px', border: '0', background: 'transparent', color: 'inherit', font: 'inherit', textAlign: 'inherit', position: 'absolute', left: '0', top: '0', opacity: '0', pointerEvents: 'none', height: '0' },
    '.cm-mvp-table-input:focus': { position: 'static', opacity: '1', pointerEvents: 'auto', height: 'auto', outline: '2px solid #1769aa', outlineOffset: '-2px' },
    '.cm-mvp-table td:focus-within .cm-mvp-table-preview, .cm-mvp-table th:focus-within .cm-mvp-table-preview': { display: 'none' },
    '.cm-mvp-table-hint': { display: 'none', font: '12px system-ui', color: '#5f6368', padding: '5px 0' },
    '.cm-mvp-table:focus-within .cm-mvp-table-hint': { display: 'block' },
  }),
];
