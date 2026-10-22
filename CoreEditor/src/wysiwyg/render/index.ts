import { syntaxTree } from '@codemirror/language';
import { EditorSelection, StateField, type EditorState, type Range } from '@codemirror/state';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';
import { loadKatex, loadMermaid } from '../assets';
import { selectionReveals } from '../hiddenSyntax/selection';

let diagramID = 0;

class RenderWidget extends WidgetType {
  constructor(readonly source: string, readonly kind: 'math' | 'mermaid', readonly block: boolean, readonly from: number) {
    super();
  }

  eq(other: RenderWidget) {
    return this.source === other.source && this.kind === other.kind && this.block === other.block && this.from === other.from;
  }

  toDOM(view: EditorView) {
    const element = document.createElement('span');
    element.className = this.block ? 'km-render km-render-block' : 'km-render';
    element.textContent = this.source;
    element.setAttribute('role', 'button');
    element.setAttribute('aria-label', this.source);
    element.tabIndex = 0;
    const reveal = () => {
      view.dispatch({ selection: EditorSelection.cursor(this.from), scrollIntoView: true });
      view.focus();
    };
    element.addEventListener('click', reveal);
    element.addEventListener('keydown', event => {
      if (event.key === 'Enter') {
        event.preventDefault();
        reveal();
      }
    });
    void this.render(element, view);
    return element;
  }

  private async render(element: HTMLElement, view: EditorView) {
    try {
      if (this.kind === 'math') {
        const katex = await loadKatex();
        if (!document.contains(element)) return;
        katex.render(this.source, element, { displayMode: this.block, throwOnError: false, trust: false });
      } else {
        const mermaid = await loadMermaid();
        if (!document.contains(element)) return;
        const result = await mermaid.render(`km-diagram-${++diagramID}`, this.source);
        if (!document.contains(element)) return;
        element.innerHTML = result.svg;
      }
    } catch (error) {
      element.textContent = `${this.source}\n${String(error)}`;
      element.classList.add('km-render-error');
    }
    if (element.isConnected) view.requestMeasure();
  }

  ignoreEvent() { return true; }
}

export function renderedDecorations(state: EditorState): DecorationSet {
  const ranges: Range<Decoration>[] = [];
  syntaxTree(state).iterate({
    enter: node => {
      let kind: 'math' | 'mermaid';
      let content: string;
      let block = false;
      if (node.name === 'BlockMath') {
        kind = 'math';
        content = state.sliceDoc(node.from + 2, node.to - 2).trim();
        block = true;
      } else if (node.name === 'FencedCode') {
        const info = node.node.getChild('CodeInfo');
        const closing = node.node.lastChild;
        if (info === null || state.sliceDoc(info.from, info.to).trim() !== 'mermaid' || closing?.name !== 'CodeMark' || closing.from <= info.to) return false;
        kind = 'mermaid';
        content = state.sliceDoc(info.to, closing.from).trim();
        block = true;
      } else if (node.name === 'Paragraph' || /^ATXHeading/.test(node.name)) {
        // 只在普通文本区间识别 $...$，跳过代码、链接地址和已转义的美元符号。
        const text = state.sliceDoc(node.from, node.to);
        for (const match of text.matchAll(/==([^=\n]+)==/g)) {
          const from = node.from + match.index, to = from + match[0].length;
          if (syntaxTree(state).resolveInner(from, 1).name === 'InlineCode') continue;
          ranges.push(Decoration.mark({ class: 'km-highlight' }).range(from, to));
          if (!selectionReveals(state, from, to)) {
            ranges.push(Decoration.replace({}).range(from, from + 2), Decoration.replace({}).range(to - 2, to));
          }
        }
        for (const match of text.matchAll(/(?<![\\$])\$(?![\s$])([^\n$]*?[^\s\\$])\$(?!\d)/g)) {
          const from = node.from + match.index;
          const to = from + match[0].length;
          const inner = syntaxTree(state).resolveInner(from, 1);
          if (inner.name !== 'Paragraph' && !/^(ATXHeading|Emphasis|StrongEmphasis|Strikethrough)/.test(inner.name)) continue;
          if (!selectionReveals(state, from, to)) {
            ranges.push(Decoration.replace({ widget: new RenderWidget(match[1], 'math', false, from) }).range(from, to));
          }
        }
        return;
      } else {
        return !['CodeBlock', 'InlineCode', 'HTMLBlock'].includes(node.name);
      }
      if (content === '') return false;
      const widget = new RenderWidget(content, kind, block, node.from);
      if (selectionReveals(state, node.from, node.to)) {
        ranges.push(Decoration.widget({ widget, block, side: 1 }).range(node.to));
      } else {
        ranges.push(Decoration.replace({ widget, block }).range(node.from, node.to));
      }
      return false;
    },
  });
  return Decoration.set(ranges, true);
}

export const renderedBlocks = StateField.define<DecorationSet>({
  create: renderedDecorations,
  update(value, transaction) {
    return transaction.docChanged || transaction.selection !== undefined || transaction.reconfigured
      || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
      ? renderedDecorations(transaction.state) : value;
  },
  provide: field => EditorView.decorations.from(field),
});

export const renderTheme = EditorView.baseTheme({
  '.km-highlight': { background: 'color-mix(in srgb, Highlight 30%, transparent)' },
  '.km-render': { cursor: 'text', maxWidth: '100%', overflowX: 'auto' },
  '.km-render-block': { display: 'block', padding: '0.75em', textAlign: 'center' },
  '.km-render svg': { maxWidth: '100%', height: 'auto' },
  '.km-render-error': { color: 'var(--editor-foreground)', whiteSpace: 'pre-wrap' },
});
