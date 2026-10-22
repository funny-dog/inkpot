import { syntaxTree } from '@codemirror/language';
import { StateField, type EditorState, type Range } from '@codemirror/state';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';
import { undo, redo } from '../../@vendor/commands/history';
import { showContextMenu } from '../../api/ui';
import { readTable, serializeTable, type Table } from './model';

class TableWidget extends WidgetType {
  constructor(readonly table: Table, readonly readOnly: boolean) { super(); }

  eq(other: TableWidget) {
    return this.readOnly === other.readOnly && JSON.stringify(this.table) === JSON.stringify(other.table);
  }

  toDOM(view: EditorView) {
    const wrapper = document.createElement('div');
    wrapper.className = 'km-table';
    const table = wrapper.appendChild(document.createElement('table'));
    for (const [row, cells] of this.table.rows.entries()) {
      const tr = table.insertRow();
      for (let column = 0; column < this.table.alignments.length; column++) {
        const td = tr.appendChild(document.createElement(row === 0 ? 'th' : 'td'));
        const input = td.appendChild(document.createElement('input'));
        input.type = 'text';
        input.setAttribute('aria-label', `${row + 1}, ${column + 1}`);
        input.dataset.row = `${row}`;
        input.dataset.column = `${column}`;
        input.addEventListener('input', event => {
          if (!(event as InputEvent).isComposing) this.edit(view, input);
        });
        input.addEventListener('compositionend', () => this.edit(view, input));
        input.addEventListener('focus', () => {
          const from = Number(input.dataset.from);
          view.dispatch({ selection: { anchor: from } });
        });
        input.addEventListener('keydown', event => {
          if (event.isComposing) return;
          if (event.metaKey && event.key.toLowerCase() === 'z') {
            event.preventDefault();
            (event.shiftKey ? redo : undo)(view);
          } else if (event.key === 'Tab' || event.key === 'Enter') {
            event.preventDefault();
            const inputs = Array.from(wrapper.querySelectorAll('input'));
            const index = inputs.indexOf(input) + (event.shiftKey ? -1 : 1);
            const target = index < 0 ? undefined : inputs.at(index);
            if (target !== undefined) {
              target.focus();
            } else {
              const widget = this.current(view, wrapper);
              const position = event.shiftKey ? Math.max(0, widget.from - 1) : Math.min(view.state.doc.length, widget.to + 1);
              view.dispatch({ selection: { anchor: position }, scrollIntoView: true });
              view.focus();
            }
          }
        });
        td.addEventListener('contextmenu', event => {
          event.preventDefault();
          this.menu(view, wrapper, row, column, event);
        });
        // 右键菜单也提供键盘入口，避免只能通过鼠标修改表格结构。
        input.addEventListener('keydown', event => {
          if (event.key === 'F10' && event.shiftKey) {
            event.preventDefault();
            this.menu(view, wrapper, row, column);
          }
        });
        if (cells.at(column) === undefined) input.placeholder = '…';
      }
    }
    this.updateDOM(wrapper);
    return wrapper;
  }

  updateDOM(wrapper: HTMLElement) {
    if (wrapper.querySelectorAll('tr').length !== this.table.rows.length
      || wrapper.querySelectorAll('tr:first-child input').length !== this.table.alignments.length) return false;
    wrapper.dataset.from = `${this.table.from}`;
    wrapper.dataset.to = `${this.table.to}`;
    for (const input of wrapper.querySelectorAll('input')) {
      const row = Number(input.dataset.row), column = Number(input.dataset.column);
      const cell = this.table.rows[row].at(column);
      input.disabled = this.readOnly;
      input.dataset.from = `${cell?.from ?? this.table.to}`;
      input.dataset.to = `${cell?.to ?? this.table.to}`;
      input.dataset.source = cell?.text ?? '';
      if (input.value !== (cell?.text ?? '')) input.value = cell?.text ?? '';
      const alignment = this.table.alignments[column];
      input.style.textAlign = alignment.startsWith(':') ? (alignment.endsWith(':') ? 'center' : 'left') : alignment.endsWith(':') ? 'right' : 'left';
    }
    return true;
  }

  private current(view: EditorView, wrapper: HTMLElement) {
    return readTable(view.state, Number(wrapper.dataset.from), Number(wrapper.dataset.to));
  }

  private edit(view: EditorView, input: HTMLInputElement) {
    if (view.state.readOnly || !view.state.facet(EditorView.editable)) return;
    const wrapper = input.closest<HTMLElement>('.km-table');
    if (wrapper === null) return;
    const table = this.current(view, wrapper);
    const row = Number(input.dataset.row), column = Number(input.dataset.column);
    const cell = table.rows[row].at(column);
    const value = input.value.replace(/\r?\n/g, ' ').replace(/(?<!\\)\|/g, '\\|');
    if (cell !== undefined) {
      view.dispatch({ changes: { from: cell.from, to: cell.to, insert: value }, userEvent: 'input' });
    } else {
      const rows = table.rows.map(cells => Array.from({ length: table.alignments.length }, (_, index) => cells.at(index)?.text ?? ''));
      rows[row][column] = value;
      this.replace(view, table, rows, table.alignments);
    }
  }

  private menu(view: EditorView, wrapper: HTMLElement, row: number, column: number, event?: MouseEvent) {
    if (view.state.readOnly || !view.state.facet(EditorView.editable)) return;
    const table = this.current(view, wrapper);
    const labels = navigator.language.startsWith('zh')
      ? ['在上方插入行', '在下方插入行', '在左侧插入列', '在右侧插入列', '删除行', '删除列']
      : ['Insert Row Above', 'Insert Row Below', 'Insert Column Before', 'Insert Column After', 'Delete Row', 'Delete Column'];
    const doc = view.state.doc;
    const items = labels.map((title, action) => ({
      title,
      action: () => {
        // 原生菜单异步返回后，文档可能已被其他操作更新。
        if (view.state.doc !== doc || view.state.readOnly || !view.state.facet(EditorView.editable)) return;
        const rows = table.rows.map(cells => Array.from({ length: table.alignments.length }, (_, index) => cells.at(index)?.text ?? ''));
        const alignments = [...table.alignments];
        if (action <= 1) rows.splice(Math.max(1, row + action), 0, alignments.map(() => ''));
        if (action === 2 || action === 3) {
          const index = column + action - 2;
          rows.forEach(cells => cells.splice(index, 0, ''));
          alignments.splice(index, 0, '---');
        }
        if (action === 4) {
          if (row === 0) return;
          rows.splice(row, 1);
        }
        if (action === 5) {
          if (alignments.length === 1) return;
          rows.forEach(cells => cells.splice(column, 1));
          alignments.splice(column, 1);
        }
        this.replace(view, table, rows, alignments);
      },
    }));
    showContextMenu(items, event === undefined ? undefined : { x: event.clientX, y: event.clientY });
  }

  private replace(view: EditorView, table: Table, rows: string[][], alignments: string[]) {
    view.dispatch({
      changes: { from: table.from, to: table.to, insert: serializeTable(rows, alignments, view.state.lineBreak) },
      userEvent: 'input',
    });
  }

  ignoreEvent() { return true; }
}

function tableDecorations(state: EditorState) {
  const ranges: Range<Decoration>[] = [];
  syntaxTree(state).iterate({ enter: node => {
    if (node.name !== 'Table' || node.node.parent?.name !== 'Document') return;
    ranges.push(Decoration.replace({
      block: true,
      widget: new TableWidget(readTable(state, node.from, node.to), state.readOnly || !state.facet(EditorView.editable)),
    }).range(node.from, node.to));
    return false;
  } });
  return Decoration.set(ranges, true);
}

const tables = StateField.define<DecorationSet>({
  create: tableDecorations,
  update(value, transaction) {
    return transaction.docChanged || transaction.reconfigured || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
      ? tableDecorations(transaction.state) : value;
  },
  provide: field => EditorView.decorations.from(field),
});

export function interactiveTables() {
  return [tables, EditorView.baseTheme({
    '.km-table': { overflowX: 'auto', padding: '0.5em 0' },
    '.km-table table': { borderCollapse: 'collapse', width: '100%', color: 'inherit' },
    '.km-table th, .km-table td': { border: '1px solid color-mix(in srgb, currentColor 25%, transparent)', padding: '0' },
    '.km-table input': { boxSizing: 'border-box', width: '100%', minWidth: '5em', padding: '0.5em', border: '0', background: 'transparent', color: 'inherit', font: 'inherit' },
    '.km-table th input': { fontWeight: 'bold' },
    '.km-table input:focus': { outline: '2px solid Highlight', outlineOffset: '-2px' },
  })];
}
