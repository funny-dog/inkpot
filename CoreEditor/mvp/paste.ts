import TurndownService from 'turndown';
import { EditorView } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { isComposing, sourceMode } from './mode';

// 富文本粘贴：读取剪贴板的 HTML，用 Turndown 转成 Markdown 源码插入。
// 转换风格与编辑器格式命令一致：ATX 标题、- 列表、围栏代码块、* 斜体。
const turndown = new TurndownService({
  headingStyle: 'atx', bulletListMarker: '-', codeBlockStyle: 'fenced', emDelimiter: '*',
});

turndown.remove(['script', 'style', 'iframe', 'object']);
// 核心包不带删除线规则（在 gfm 插件里），编辑器支持 ~~语法~~，自己补上。
turndown.addRule('strikethrough', {
  filter: ['del', 's'],
  replacement: content => `~~${content}~~`,
});
// Turndown 7 默认输出 "-   "（三空格），与编辑器续写的 "- " 不一致，覆盖为单空格。
turndown.addRule('listItem', {
  filter: 'li',
  replacement: (content, node, options) => {
    const parent = node.parentNode;
    let prefix = `${options.bulletListMarker} `;
    if (parent instanceof HTMLOListElement) {
      const index = Array.prototype.indexOf.call(parent.children, node);
      prefix = `${parent.start + index}. `;
    }
    const isParagraph = /\n$/.test(content);
    const text = (content.replace(/^\n+/, '').replace(/\n+$/, '') + (isParagraph ? '\n' : ''))
      .replace(/\n/gm, `\n${' '.repeat(prefix.length)}`);
    return prefix + text + (node.nextSibling ? '\n' : '');
  },
});
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
    // 源码模式粘贴的是源码文本本身，转换会把 Markdown 字符误转义（如 # 变 \#）。
    if (view.state.field(sourceMode, false) === true || isComposing(view)) return false;
    // 表格单元格等输入框里的粘贴保持原生行为，不能改写文档选区。
    const target = event.target;
    if (!(target instanceof Node) || !view.contentDOM.contains(target)
      || target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return false;
    // 代码和 HTML 源码中沿用纯文本粘贴，避免插入格式标记或转义代码字符。
    for (const range of view.state.selection.ranges) {
      let node = syntaxTree(view.state).resolveInner(range.from, 1);
      while (node.parent !== null) {
        if (['InlineCode', 'FencedCode', 'CodeBlock', 'HTMLBlock'].includes(node.name)) return false;
        node = node.parent;
      }
    }
    // 图片文件交给编辑器既有的图片粘贴流程。
    if ([...(event.clipboardData?.files ?? [])].some(file => file.type.startsWith('image/'))) return false;
    const html = event.clipboardData?.getData('text/html') ?? '';
    if (html === '') return false;
    try {
      const text = htmlToMarkdown(html);
      if (text === '') return false;
      view.dispatch({ ...view.state.replaceSelection(text), scrollIntoView: true, userEvent: 'input.paste' });
      event.preventDefault();
      return true;
    } catch (error) {
      console.error('富文本转换失败，改用纯文本粘贴：', error);
      return false;
    }
  },
});
