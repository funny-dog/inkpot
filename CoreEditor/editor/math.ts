import { EditorState, Range, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { Command, Decoration, DecorationSet, EditorView, WidgetType } from '@codemirror/view';
import { MarkdownConfig } from '@lezer/markdown';
import { SyntaxNode } from '@lezer/common';
import { mathTag } from './math-parser';
import { selectionMissesBlocks, topBlocks } from './blocks';
import { selectionTouches } from './basic';
import { isComposing, previewExport, sourceMode } from './mode';

export { blockMathTagName, blockMathContentTagName, markdownMathExtension, mathTag } from './math-parser';

export const inlineMathTagName = 'InlineMath';
const inlineMathMarkTagName = 'InlineMathMark';

// 行内公式 $…$：开标记后不能是空白、前后不能紧邻另一个 $（$$ 属于块级语法），闭标记前不能是空白、后不能紧跟数字（货币金额保持原样）；不跨行，\$ 已转义。
export const inlineMathExtension: MarkdownConfig = {
  defineNodes: [
    { name: inlineMathTagName, style: mathTag },
    { name: inlineMathMarkTagName },
  ],
  parseInline: [{
    name: inlineMathTagName,
    parse(cx, next, pos) {
      if (next !== 36 || cx.char(pos + 1) === 36 || cx.char(pos + 1) <= 32 || cx.char(pos - 1) === 36) return -1;
      let backslashes = 0;
      while (cx.char(pos - backslashes - 1) === 92) backslashes++;
      if (backslashes % 2 === 1) return -1;
      for (let index = pos + 1; index < cx.end; index++) {
        const char = cx.char(index);
        if (char === 92) { index++; continue; }
        if (char === 36) {
          if (cx.char(index - 1) <= 32) return -1;
          const after = cx.char(index + 1);
          if (after >= 48 && after <= 57) return -1;
          return cx.addElement(cx.elt(inlineMathTagName, pos, index + 1, [
            cx.elt(inlineMathMarkTagName, pos, pos + 1),
            cx.elt(inlineMathMarkTagName, index, index + 1),
          ]));
        }
        if (char === 10) return -1;
      }
      return -1;
    },
  }],
};

type Katex = { render(tex: string, element: HTMLElement, options: { displayMode: boolean; throwOnError: boolean; trust: boolean }): void };

// KaTeX 是现有依赖；从应用包按需加载，文档没有公式时不增加启动开销。测试注入替代实现。
const assetBase = 'inkpot-asset://math/';

async function loadFromApp(): Promise<Katex> {
  if (document.querySelector('link[data-katex]') === null) {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = `${assetBase}katex.min.css`;
    link.dataset.katex = '';
    document.head.appendChild(link);
  }
  const module = await import(/* @vite-ignore */ `${assetBase}katex.mjs`) as { default?: Katex } & Katex;
  return module.default ?? module;
}

let load: () => Promise<Katex> = loadFromApp;

export function useKatexForTests(module: Katex) {
  load = () => Promise.resolve(module);
}

let katexPromise: Promise<Katex> | undefined;

async function loadKatex(): Promise<Katex> {
  try {
    return await (katexPromise ??= load());
  } catch (error) {
    katexPromise = undefined;
    throw error;
  }
}

class MathPreview extends WidgetType {
  constructor(readonly source: string, readonly display: boolean, private readonly anchor: number) { super(); }
  eq(other: MathPreview) { return this.source === other.source && this.display === other.display && this.anchor === other.anchor; }
  toDOM(view: EditorView) {
    const element: HTMLElement = document.createElement(this.display ? 'div' : 'span');
    element.className = this.display ? 'cm-inkpot-math cm-inkpot-math-block' : 'cm-inkpot-math';
    element.setAttribute('aria-label', `公式源码：${this.source}`);
    const editable = !view.state.readOnly && view.state.facet(EditorView.editable);
    if (editable) element.title = '点击编辑公式源码';
    // 加载完成前先显示源码，资源缺失或渲染失败时也绝不留空。
    element.textContent = this.source;
    void (async () => {
      try {
        const katex = await loadKatex();
        if (!element.isConnected) return;
        katex.render(this.source, element, { displayMode: this.display, throwOnError: false, trust: false });
      } catch {
        if (element.isConnected) {
          element.classList.add('cm-inkpot-math-error');
          element.textContent = this.source;
        }
      }
    })();
    element.addEventListener('mousedown', event => {
      if (event.button !== 0) return;
      // 始终拦截对公式的默认点击定位，只读和组合输入期间保持渲染不进入编辑。
      event.preventDefault();
      if (!editable || view.compositionStarted) return;
      view.dispatch({ selection: { anchor: this.anchor }, scrollIntoView: true });
      view.focus();
    });
    return element;
  }
  ignoreEvent() { return false; }
}

export function mathDecorations(node: SyntaxNode, view: EditorView, searchSelection: boolean) {
  const { state } = view;
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  const source = state.sliceDoc(node.from + 1, node.to - 1);
  // 光标进入元素或搜索命中标记时局部展开源码，其余时间渲染公式。
  const editing = selectionTouches(state, node.from, node.to, true);
  const searching = searchSelection && selectionTouches(state, node.from, node.to, false);
  if (((!editing && !searching) || state.field(previewExport)) && source.length > 0) {
    const replacement = Decoration.replace({ widget: new MathPreview(source, false, node.from + 1) }).range(node.from, node.to);
    decorations.push(replacement);
    atoms.push(replacement);
  }
  return { decorations, atoms };
}

// 块级装饰必须由 StateField 提供；搜索命中标记时临时展开源码。
const mathSearch = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.isUserEvent('select.search') ? true : transaction.selection !== undefined || transaction.docChanged ? false : value,
});

function blockDecorations(state: EditorState) {
  const exporting = state.field(previewExport);
  if (state.field(sourceMode) && !exporting) return Decoration.none;
  const ranges: Range<Decoration>[] = [];
  const selection = state.selection.main;
  for (const node of topBlocks(state).math) {
    if (!exporting && (selectionTouches(state, node.from, node.to, true)
      || (state.field(mathSearch) && selection.from < node.to && selection.to > node.from))) continue;
    const source = state.sliceDoc(node.from + 2, node.to - 2).trim();
    if (source.length === 0) continue;
    // 块级替换必须覆盖整行；闭标记总在行尾，开标记在行首。
    const from = state.doc.lineAt(node.from).from;
    const to = state.doc.lineAt(node.to).to;
    ranges.push(Decoration.replace({ block: true, widget: new MathPreview(source, true, node.from + 2) }).range(from, to));
  }
  return Decoration.set(ranges, true);
}

const mathBlocks = StateField.define<DecorationSet>({
  create: blockDecorations,
  update: (value, transaction) => transaction.docChanged || transaction.reconfigured
    || transaction.startState.field(previewExport) !== transaction.state.field(previewExport)
    || transaction.startState.field(sourceMode) !== transaction.state.field(sourceMode)
    || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
    || (transaction.selection !== undefined && !selectionMissesBlocks(transaction, blocks => blocks.math)) ? blockDecorations(transaction.state) : value,
  provide: field => EditorView.decorations.from(field),
});

export const mathEditing = [
  mathSearch, mathBlocks,
  EditorView.atomicRanges.of(view => view.state.field(mathBlocks)),
];

function inContainer(state: EditorState, position: number) {
  let node: SyntaxNode | null = syntaxTree(state).resolveInner(position, 1);
  while (node !== null) {
    if (['Table', 'FencedCode', 'CodeBlock', 'HTMLBlock', 'ListItem', 'Blockquote'].includes(node.name)) return true;
    node = node.parent;
  }
  return false;
}

export const mathCommands: Readonly<Record<string, Command>> = {
  insertMathBlock: view => {
    if (view.state.readOnly || !view.state.facet(EditorView.editable) || isComposing(view)) return false;
    if (inContainer(view.state, view.state.selection.main.head)) return false;
    const { state } = view;
    const { from, to } = state.selection.main;
    const line = state.doc.lineAt(from);
    const atEmptyLine = from === to && from === line.from && line.text.length === 0;
    // 闭合 $$ 必须独占行尾；行内有剩余文字时补空行分隔。
    const prefix = atEmptyLine ? '' : from > 0 ? '\n\n' : '';
    const suffix = atEmptyLine || to >= line.to ? '' : '\n\n';
    const change = { from, to, insert: `${prefix}$$\n\n$$${suffix}` };
    view.dispatch(state.update({
      changes: change,
      selection: { anchor: from + prefix.length + 3 },
      annotations: isolateHistory.of('full'),
      userEvent: 'input.math',
      scrollIntoView: true,
    }));
    view.focus();
    return true;
  },
};

export const mathTheme = EditorView.theme({
  '.cm-inkpot-math': { cursor: 'pointer', backgroundColor: 'rgba(23, 106, 170, 0.08)', borderRadius: '3px', padding: '0 2px', overflowWrap: 'anywhere' },
  '.cm-inkpot-math-block': { display: 'block', textAlign: 'center', margin: '10px 0', padding: '6px 0', overflowX: 'auto' },
  '.cm-inkpot-math-error': { color: '#b3261e' },
});
