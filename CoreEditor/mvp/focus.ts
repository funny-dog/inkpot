import { Compartment, Extension, Range, StateEffect, EditorState } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';
import type { SyntaxNode } from '@lezer/common';
import { isComposing, previewExport } from './mode';
import { blockMathTagName } from './math-parser';

// 专注模式：淡化光标所在块以外的可见行；打字机模式：光标移动或输入后把光标行滚到视口垂直居中附近。
// 两者都只影响显示，不产生文档事务、不进入撤销历史；导出（previewExport）期间全部让位。

interface BlockRange {
  from: number;
  to: number;
}

const blockNodeNames = new RegExp(`^(FencedCode|CodeBlock|HTMLBlock|Table|ListItem|HorizontalRule|${blockMathTagName}|ATXHeading[1-6]|SetextHeading[12])$`);

/**
 * 光标所在块的原文范围：段落、列表项、代码块、表格、公式块保持正常；
 * 空行仅在仍处于代码块、表格或列表项内部时延续所属结构，否则只保持当前行。
 */
export function activeBlockRange(state: EditorState, pos: number): BlockRange {
  const line = state.doc.lineAt(pos);
  const fallback: BlockRange = { from: line.from, to: line.to };
  if (line.length === 0) {
    // 空行没有所属段落，仅当仍处于跨行结构内部时延续该结构，否则只保持当前行。
    let node: SyntaxNode | null = syntaxTree(state).resolveInner(line.from, 1);
    while (node !== null) {
      if (node.from <= line.from && node.to > line.from && blockNodeNames.test(node.name)) {
        return { from: node.from, to: node.to };
      }
      node = node.parent;
    }
    return fallback;
  }
  // 块的归属只取决于行，取行内一个稳定位置解析，避免在行边界上解析到相邻块。
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(line.from + 1, -1);
  while (node !== null && !(node.from <= line.from && node.to >= line.to)) {
    node = node.parent;
  }
  // 覆盖行的最内层节点可能只是行内元素、代码正文或内嵌语言树的节点，继续向上找所属块级节点。
  while (node !== null && !blockNodeNames.test(node.name)) {
    node = node.parent;
  }
  if (node === null) return fallback;
  if (node.name === 'Paragraph' && node.parent?.name === 'ListItem') return { from: node.parent.from, to: node.parent.to };
  return { from: node.from, to: node.to };
}

const dimLine = Decoration.line({ class: 'cm-focus-dim' });

/** 行是否属于活动块的保持范围：空行只在严格位于块内部或恰为活动行本身时保持。 */
function lineKept(line: { from: number; to: number }, block: BlockRange): boolean {
  if (block.from === block.to) return line.from === block.from;
  return block.from <= line.from && (line.to === line.from ? line.from < block.to : line.to <= block.to);
}

function focusDecorations(view: EditorView): DecorationSet {
  if (view.state.field(previewExport)) return Decoration.none;
  const { state } = view;
  const blocks: BlockRange[] = [];
  for (const range of state.selection.ranges) {
    blocks.push(activeBlockRange(state, range.head));
    if (!range.empty) blocks.push(activeBlockRange(state, range.to));
  }
  const decorations: Range<Decoration>[] = [];
  for (const { from, to } of view.visibleRanges) {
    const first = state.doc.lineAt(from).number;
    const last = state.doc.lineAt(to - 1).number;
    for (let number = first; number <= last; number++) {
      const line = state.doc.line(number);
      if (blocks.some(block => lineKept(line, block))) continue;
      decorations.push(dimLine.range(line.from));
    }
  }
  return Decoration.set(decorations, true);
}

const refreshFocus = StateEffect.define();

const focusPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  private refreshTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(view: EditorView) {
    this.decorations = focusDecorations(view);
  }

  update(update: ViewUpdate) {
    // 组合输入期间不重建候选文字周围的装饰，只映射已有装饰，结束后统一刷新。
    if (isComposing(update.view)) {
      this.decorations = this.decorations.map(update.changes);
      return;
    }
    if (update.docChanged || update.selectionSet || update.viewportChanged
      || update.transactions.some(transaction => transaction.effects.length > 0)
      || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = focusDecorations(update.view);
    }
  }

  compositionEnded(view: EditorView) {
    clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => view.dispatch({ effects: refreshFocus.of(null) }), 80);
  }

  destroy() { clearTimeout(this.refreshTimer); }
}, {
  decorations: value => value.decorations,
  eventHandlers: { compositionend(_event, view) { this.compositionEnded(view); } },
});

function centerCaret(view: EditorView) {
  view.dispatch({ effects: EditorView.scrollIntoView(view.state.selection.main.head, { y: 'center', yMargin: 0 }) });
}

const typewriterExtension = EditorView.updateListener.of(update => {
  if (!update.docChanged && !update.selectionSet) return;
  // 导出期间原生会临时移动选区，此时不滚动。
  if (update.state.field(previewExport) || update.startState.field(previewExport)) return;
  centerCaret(update.view);
});

const focusTheme = EditorView.theme({
  '.cm-focus-dim': { opacity: '0.2' },
});

const focusExtension: Extension[] = [focusTheme, focusPlugin];

const focusCompartment = new Compartment();
const typewriterCompartment = new Compartment();
let focusEnabled = false;
let typewriterEnabled = false;

/** 打开文档时的初始扩展：沿用当前全局偏好，原生随后会同步一次。 */
export function displayExtensions(): Extension[] {
  return [focusCompartment.of(focusEnabled ? focusExtension : []), typewriterCompartment.of(typewriterEnabled ? typewriterExtension : [])];
}

/** 原生偏好变化：两种模式可独立开关，缺省的键保持现状。 */
export function applyDisplayModes(view: EditorView, modes: { focus?: boolean; typewriter?: boolean }): void {
  if (modes.focus !== undefined) focusEnabled = modes.focus;
  if (modes.typewriter !== undefined) typewriterEnabled = modes.typewriter;
  view.dispatch({ effects: [
    focusCompartment.reconfigure(focusEnabled ? focusExtension : []),
    typewriterCompartment.reconfigure(typewriterEnabled ? typewriterExtension : []),
  ] });
}
