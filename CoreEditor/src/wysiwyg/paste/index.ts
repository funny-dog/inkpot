import TurndownService from 'turndown';
import { EditorView } from '@codemirror/view';

const turndown = new TurndownService({
  headingStyle: 'atx', bulletListMarker: '-', codeBlockStyle: 'fenced', emDelimiter: '*',
});

turndown.remove(['script', 'style', 'iframe', 'object']);
turndown.addRule('table', {
  filter: 'table',
  replacement: (_content, node) => {
    const rows = Array.from((node as HTMLTableElement).rows, row => Array.from(row.cells, cell =>
      turndown.turndown(cell.innerHTML).replace(/\|/g, '\\|').replace(/\n+/g, '<br>')));
    const columns = Math.max(...rows.map(row => row.length));
    if (rows.length === 0 || columns === 0) return '';
    const lines = rows.map(row => `| ${Array.from({ length: columns }, (_, index) => row[index] ?? '').join(' | ')} |`);
    lines.splice(1, 0, `| ${Array(columns).fill('---').join(' | ')} |`);
    return `\n\n${lines.join('\n')}\n\n`;
  },
});

export function htmlToMarkdown(html: string) {
  return turndown.turndown(html);
}

export const richPaste = EditorView.domEventHandlers({
  paste(event, view) {
    if (view.state.readOnly || !view.state.facet(EditorView.editable)) return false;
    const html = event.clipboardData?.getData('text/html') ?? '';
    if (html === '') return false;
    try {
      const text = htmlToMarkdown(html);
      if (text === '') return false;
      view.dispatch({ ...view.state.replaceSelection(text), scrollIntoView: true, userEvent: 'input.paste' });
      event.preventDefault();
      return true;
    } catch (error) {
      console.error('富文本转换失败，使用纯文本粘贴：', error);
      return false;
    }
  },
});
