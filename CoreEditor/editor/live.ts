import { Range, StateEffect } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { Decoration, DecorationSet, EditorView, keymap, ViewPlugin, ViewUpdate, WidgetType } from '@codemirror/view';
import { sourceMode, toggleSourceMode, isComposing, previewExport } from './mode';
import { hasMermaidPreview, mermaidEditing } from './mermaid';
import { tableEditing } from './table';
export { sourceMode, toggleSourceMode } from './mode';
import { imageDecorations, imageRevision, remoteImages } from './image';
import { basicDecorations, selectionTouches } from './basic';
import { codeBindings, codeDecorations, codeTheme, editingCodeLanguage } from './code';
import { inlineMathTagName, mathDecorations, mathEditing, mathTheme } from './math';
import { footnoteRefTagName, gfmDecorations, gfmEditing, inlineHighlightTagName, inlineMarkNames } from './gfm';

const refreshPreview = StateEffect.define();

class ListMarker extends WidgetType {
  constructor(private readonly text: string) { super(); }
  eq(other: ListMarker) { return this.text === other.text; }
  toDOM() {
    const dom = document.createElement('span');
    dom.className = 'cm-inkpot-list-marker';
    dom.textContent = this.text;
    return dom;
  }
  ignoreEvent() { return false; }
}

function previewDecorations(view: EditorView, searchSelection = false) {
  const { state } = view;
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  const quoteLines = new Set<number>();
  if (state.field(sourceMode)) return { decorations: Decoration.none, atoms: Decoration.none };

  // 搜索标记本身时也必须能看见匹配项；只暂时展开命中元素，不切换文档模式。
  function selected(from: number, to: number, includeCursor: boolean) {
    return selectionTouches(state, from, to, includeCursor);
  }
  function hide(from: number, to: number, widget?: WidgetType) {
    if (from >= to || (searchSelection && selected(from, to, false))) return;
    const range = Decoration.replace({ widget }).range(from, to);
    decorations.push(range);
    atoms.push(range);
  }
  function afterSpaces(from: number, to: number) {
    return from + (/^[ \t]*/.exec(state.sliceDoc(from, to))?.[0].length ?? 0);
  }
  syntaxTree(state).iterate({
    from: view.viewport.from,
    to: view.viewport.to,
    enter(node) {
      if (node.name === 'Table') {
        return false;
      } else if (node.name === inlineMathTagName) {
        const math = mathDecorations(node.node, view, searchSelection);
        decorations.push(...math.decorations);
        atoms.push(...math.atoms);
        return false;
      } else if (node.name === 'Image') {
        const image = imageDecorations(node.node, state);
        decorations.push(...image.decorations);
        atoms.push(...image.atoms);
        return false;
      } else if (node.name === 'FencedCode') {
        if (hasMermaidPreview(state, node.from)) return false;
        const code = codeDecorations(node.node, view, searchSelection);
        decorations.push(...code.decorations);
        atoms.push(...code.atoms);
      } else if (['InlineCode', 'Link', 'Autolink', 'HorizontalRule', 'SetextHeading1', 'SetextHeading2'].includes(node.name)) {
        const basic = basicDecorations(node.node, view, searchSelection);
        decorations.push(...basic.decorations);
        atoms.push(...basic.atoms);
      } else if (node.name === 'StrongEmphasis' || node.name === 'Emphasis' || node.name === 'Strikethrough' || node.name === inlineHighlightTagName) {
        if (!selected(node.from, node.to, true)) {
          const markName = inlineMarkNames[node.name] ?? 'EmphasisMark';
          for (const mark of node.node.getChildren(markName)) {
            // 保留标记的文本节点，光标进入元素时可直接恢复局部源码。
            decorations.push(Decoration.mark({ class: 'cm-inkpot-hidden-inline' }).range(mark.from, mark.to));
          }
        }
      } else if (node.name === 'TaskMarker' || node.name === footnoteRefTagName) {
        const gfm = gfmDecorations(node.node, view, searchSelection);
        decorations.push(...gfm.decorations);
        atoms.push(...gfm.atoms);
        return false;
      } else if (/^ATXHeading[1-6]$/.test(node.name)) {
        decorations.push(Decoration.line({ class: `cm-inkpot-heading${node.name.slice(-1)}` }).range(state.doc.lineAt(node.from).from));
        const marks = node.node.getChildren('HeaderMark');
        for (let index = 0; index < marks.length; index++) {
          const mark = marks[index];
          hide(mark.from, index === 0 ? afterSpaces(mark.to, node.to) : mark.to);
        }
      } else if (node.name === 'ListMark') {
        const line = state.doc.lineAt(node.from);
        const text = state.sliceDoc(node.from, node.to);
        hide(node.from, afterSpaces(node.to, line.to), new ListMarker(/^\d/.test(text) ? `${parseInt(text, 10)}. ` : '• '));
      } else if (node.name === 'QuoteMark') {
        const line = state.doc.lineAt(node.from);
        hide(node.from, afterSpaces(node.to, line.to));
      } else if (node.name === 'Blockquote') {
        const first = state.doc.lineAt(Math.max(node.from, view.viewport.from)).number;
        const last = state.doc.lineAt(Math.min(node.to, view.viewport.to)).number;
        for (let line = first; line <= last; line++) quoteLines.add(state.doc.line(line).from);
      }
    },
  });
  for (const from of quoteLines) decorations.push(Decoration.line({ class: 'cm-inkpot-quote' }).range(from));
  return { decorations: Decoration.set(decorations, true), atoms: Decoration.set(atoms, true) };
}

const preview = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  atoms: DecorationSet;
  private refreshTimer: ReturnType<typeof setTimeout> | undefined;
  private searchSelection = false;

  constructor(view: EditorView) {
    const result = previewDecorations(view);
    this.decorations = result.decorations;
    this.atoms = result.atoms;
  }

  update(update: ViewUpdate) {
    if (update.transactions.some(transaction => transaction.isUserEvent('select.search'))) {
      this.searchSelection = true;
    } else if (update.selectionSet || update.docChanged) {
      this.searchSelection = false;
    }
    // 组合输入期间不重建候选文字周围的 DOM，只映射已存在的装饰。
    if (isComposing(update.view)) {
      this.decorations = this.decorations.map(update.changes);
      this.atoms = this.atoms.map(update.changes);
    } else if (update.docChanged || update.selectionSet || update.viewportChanged
      || syntaxTree(update.startState) !== syntaxTree(update.state)
      || update.transactions.some(transaction => transaction.effects.length > 0)) {
      const result = previewDecorations(update.view, this.searchSelection);
      this.decorations = result.decorations;
      this.atoms = result.atoms;
    }
  }

  compositionEnded(view: EditorView) {
    clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => view.dispatch({ effects: refreshPreview.of(null) }), 80);
  }

  destroy() { clearTimeout(this.refreshTimer); }
}, {
  decorations: value => value.decorations,
  provide: plugin => EditorView.atomicRanges.of(view => view.plugin(plugin)?.atoms ?? Decoration.none),
  eventHandlers: { compositionend(_event, view) { this.compositionEnded(view); } },
});

export const liveEditing = [
  sourceMode, previewExport, remoteImages,
  ...mermaidEditing,
  ...tableEditing,
  ...mathEditing,
  ...gfmEditing,
  imageRevision,
  editingCodeLanguage,
  codeTheme,
  mathTheme,
  preview,
  keymap.of([
    { key: 'Mod-Shift-m', run: toggleSourceMode },
    ...codeBindings.map(binding => ({ ...binding,
      run: (view: EditorView) => isComposing(view) ? true
        : view.state.field(sourceMode) || (view.state.readOnly && ['Enter', 'Backspace', 'Delete', 'Tab'].includes(binding.key ?? ''))
          ? false : binding.run?.(view) ?? false,
      shift: binding.shift === undefined ? undefined : (view: EditorView) => isComposing(view) ? true
        : view.state.field(sourceMode) || view.state.readOnly ? false : binding.shift?.(view) ?? false,
    })),
  ]),
  EditorView.editorAttributes.of(view => ({ class: view.state.field(sourceMode) ? 'cm-inkpot-source' : 'cm-inkpot-live' })),
  EditorView.theme({
    '&.cm-inkpot-live .cm-scroller': { fontFamily: 'var(--inkpot-body-font, system-ui, sans-serif)', fontSize: 'var(--inkpot-body-size, 15px)' },
    '.cm-inkpot-hidden-inline, .cm-inkpot-hidden-inline *': { fontSize: '0 !important' },
    '.cm-inkpot-image': { display: 'inline-block', maxWidth: '100%', verticalAlign: 'middle', margin: '6px 0' },
    '.cm-inkpot-image img': { display: 'block', maxWidth: '100%', maxHeight: '420px', objectFit: 'contain' },
    '.cm-inkpot-inline-code': { fontFamily: 'var(--inkpot-code-font, Menlo, monospace)', fontSize: 'var(--inkpot-code-size, 15px)', backgroundColor: '#f1f1f4', borderRadius: '4px' },
    '.cm-inkpot-link': { color: '#2b5a8c', textDecoration: 'underline', textUnderlineOffset: '3px', cursor: 'text' },
    '.cm-inkpot-rule': { display: 'inline-block', width: '100%', borderTop: '1px solid #d2d2d7', verticalAlign: 'middle' },
    '.cm-inkpot-setext-mark': { height: '0', minHeight: '0', lineHeight: '0', paddingTop: '0', paddingBottom: '0' },
    '.cm-inkpot-list-marker': { whiteSpace: 'pre', color: '#6e6e73' },
    '.cm-inkpot-quote': { borderLeft: '3px solid #d2d2d7', paddingLeft: '16px', color: '#6e6e73' },
    // 标题段前留白用 padding（CodeMirror 按 DOM 实测行高，margin 会让高度测量出错）；em 相对标题自身字号。
    '.cm-inkpot-heading1': { fontSize: '1.8em', fontWeight: 'bold', lineHeight: '1.35', paddingTop: '0.7em', paddingBottom: '0.15em' },
    '.cm-inkpot-heading2': { fontSize: '1.4em', fontWeight: 'bold', lineHeight: '1.4', paddingTop: '0.7em', paddingBottom: '0.1em' },
    '.cm-inkpot-heading3': { fontSize: '1.2em', fontWeight: 'bold', lineHeight: '1.45', paddingTop: '0.6em' },
    '.cm-inkpot-heading4': { fontSize: '1.08em', fontWeight: 'bold', paddingTop: '0.5em' },
    '.cm-inkpot-heading5': { fontSize: '1em', fontWeight: 'bold', paddingTop: '0.4em' },
    '.cm-inkpot-heading6': { fontSize: '0.92em', fontWeight: 'bold', paddingTop: '0.4em', color: '#6e6e73' },
  }),
];
