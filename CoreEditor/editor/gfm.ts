import { EditorState, Range, StateField, Text } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { Decoration, DecorationSet, EditorView, WidgetType } from '@codemirror/view';
import { MarkdownConfig } from '@lezer/markdown';
import { Tag, tags } from '@lezer/highlight';
import { SyntaxNode, Tree } from '@lezer/common';
import { headings } from './outline';
import { selectionMissesBlocks, topBlocks } from './blocks';
import { selectionTouches } from './basic';
import { isComposing, sourceMode } from './mode';

export const highlightTag = Tag.define();
export const inlineHighlightTagName = 'InlineHighlight';
const inlineHighlightMarkTagName = 'InlineHighlightMark';
export const footnoteRefTagName = 'FootnoteRef';
export const footnoteDefTagName = 'FootnoteDef';
export const inlineMarkNames: Record<string, string> = {
  Strikethrough: 'StrikethroughMark',
  [inlineHighlightTagName]: inlineHighlightMarkTagName,
};

// 高亮 ==文字==：成对标记、内容非空、不跨行；行首整行 = 属于 setext 标记，由块级语法先行消费。
export const highlightExtension: MarkdownConfig = {
  defineNodes: [
    { name: inlineHighlightTagName, style: highlightTag },
    { name: inlineHighlightMarkTagName },
  ],
  parseInline: [{
    name: inlineHighlightTagName,
    parse(cx, next, pos) {
      if (next !== 61 || cx.char(pos + 1) !== 61) return -1;
      for (let index = pos + 2; index < cx.end; index++) {
        const char = cx.char(index);
        if (char === 10) return -1;
        if (char === 61 && cx.char(index + 1) === 61 && index > pos + 2) {
          return cx.addElement(cx.elt(inlineHighlightTagName, pos, index + 2, [
            cx.elt(inlineHighlightMarkTagName, pos, pos + 2),
            cx.elt(inlineHighlightMarkTagName, index, index + 2),
          ]));
        }
      }
      return -1;
    },
  }],
};

// 脚注：行内 [^label] 引用与行首 [^label]: 定义；定义行保留源码并以 meta 风格呈现，不迁入跳转与聚合。
export const footnoteExtension: MarkdownConfig = {
  defineNodes: [
    { name: footnoteRefTagName, style: tags.link },
    { name: footnoteDefTagName, block: true, style: tags.meta },
  ],
  parseInline: [{
    name: footnoteRefTagName,
    // 必须先于 CommonMark 的 Link 规则处理 [，否则 [^label] 会被当成链接标签。
    before: 'Link',
    parse(cx, next, pos) {
      if (next !== 91 || cx.char(pos + 1) !== 94) return -1;
      for (let index = pos + 2; index < cx.end; index++) {
        const char = cx.char(index);
        if (char === 93) {
          // 空标签或紧跟冒号（定义行标记）的不是引用。
          if (index === pos + 2 || cx.char(index + 1) === 58) return -1;
          return cx.addElement(cx.elt(footnoteRefTagName, pos, index + 1));
        }
        if (char === 10 || char === 91 || char === 32 || char === 9) return -1;
      }
      return -1;
    },
  }],
  parseBlock: [{
    name: footnoteDefTagName,
    parse(cx, line) {
      const at = line.pos;
      if (!line.text.startsWith('[^', at)) return false;
      const close = line.text.indexOf(']', at + 2);
      if (close < 0 || close === at + 2 || line.text[close + 1] !== ':' || /\s/.test(line.text.slice(at + 2, close))) return false;
      cx.addElement(cx.elt(footnoteDefTagName, cx.lineStart + at, cx.lineStart + line.text.length));
      cx.nextLine();
      return true;
    },
  }],
};

class TaskCheckbox extends WidgetType {
  constructor(readonly checked: boolean, private readonly from: number, private readonly to: number) { super(); }
  eq(other: TaskCheckbox) { return this.checked === other.checked && this.from === other.from; }
  toDOM(view: EditorView) {
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = this.checked;
    input.setAttribute('aria-label', '任务勾选');
    const editable = !view.state.readOnly && view.state.facet(EditorView.editable);
    input.disabled = !editable;
    input.addEventListener('mousedown', event => event.preventDefault());
    input.addEventListener('click', () => {
      if (!editable || isComposing(view)) { input.checked = this.checked; return; }
      view.dispatch({
        changes: { from: this.from, to: this.to, insert: this.checked ? '[ ]' : '[x]' },
        annotations: isolateHistory.of('full'),
        userEvent: 'input.task',
      });
    });
    return input;
  }
  ignoreEvent() { return false; }
}

class FootnoteRef extends WidgetType {
  constructor(readonly label: string, readonly definition: string, private readonly anchor: number) { super(); }
  eq(other: FootnoteRef) { return this.label === other.label && this.definition === other.definition && this.anchor === other.anchor; }
  toDOM(view: EditorView) {
    const element = document.createElement('sup');
    element.className = 'cm-inkpot-footnote-ref';
    element.textContent = this.label;
    element.title = this.definition.length > 0 ? this.definition : `脚注：${this.label}`;
    if (!view.state.readOnly && view.state.facet(EditorView.editable)) {
      element.addEventListener('mousedown', event => {
        if (event.button !== 0) return;
        event.preventDefault();
        if (isComposing(view)) return;
        view.dispatch({ selection: { anchor: this.anchor }, scrollIntoView: true });
        view.focus();
      });
    }
    return element;
  }
  ignoreEvent() { return false; }
}

// 脚注定义收集：label → 定义文本；同一文档只在内容变化时扫描一次。
const definitionCache = new WeakMap<Text, Map<string, string>>();

function footnoteDefinitions(state: EditorState) {
  let definitions = definitionCache.get(state.doc);
  if (definitions === undefined) {
    definitions = new Map<string, string>();
    const pattern = /^ {0,3}\[\^([^\s[\]]+)\]:[ \t]*(.*)$/;
    for (let number = 1; number <= state.doc.lines; number++) {
      const match = pattern.exec(state.doc.line(number).text);
      if (match !== null) definitions.set(match[1], match[2]);
    }
    definitionCache.set(state.doc, definitions);
  }
  return definitions;
}

export function gfmDecorations(node: SyntaxNode, view: EditorView, searchSelection: boolean) {
  const { state } = view;
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  const editing = selectionTouches(state, node.from, node.to, true);
  const searching = searchSelection && selectionTouches(state, node.from, node.to, false);
  if (!editing && !searching) {
    if (node.name === 'TaskMarker') {
      const replacement = Decoration.replace({ widget: new TaskCheckbox(/x/i.test(state.sliceDoc(node.from, node.to)), node.from, node.to) }).range(node.from, node.to);
      decorations.push(replacement);
      atoms.push(replacement);
    } else if (node.name === footnoteRefTagName) {
      const label = state.sliceDoc(node.from + 2, node.to - 1);
      const replacement = Decoration.replace({ widget: new FootnoteRef(label, footnoteDefinitions(state).get(label) ?? '', node.from + 1) }).range(node.from, node.to);
      decorations.push(replacement);
      atoms.push(replacement);
    }
  }
  return { decorations, atoms };
}

class TableOfContents extends WidgetType {
  constructor(readonly entries: { level: number; title: string; from: number }[]) { super(); }
  eq(other: TableOfContents) { return this.entries.length === other.entries.length && this.entries.every((entry, index) => entry.level === other.entries[index].level && entry.title === other.entries[index].title); }
  toDOM(view: EditorView) {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-inkpot-toc';
    wrapper.setAttribute('aria-label', '目录');
    if (this.entries.length === 0) {
      const empty = wrapper.appendChild(document.createElement('div'));
      empty.className = 'cm-inkpot-toc-empty';
      empty.textContent = '暂无标题';
    } else {
      const editable = !view.state.readOnly && view.state.facet(EditorView.editable);
      for (const entry of this.entries) {
        const item = wrapper.appendChild(document.createElement('div'));
        item.className = 'cm-inkpot-toc-item';
        item.style.paddingLeft = `${(entry.level - 1) * 18}px`;
        item.textContent = entry.title;
        item.title = '跳转到此标题';
        item.addEventListener('mousedown', (event: MouseEvent) => {
          if (event.button !== 0) return;
          event.preventDefault();
          if (!editable || isComposing(view)) return;
          view.dispatch({ selection: { anchor: entry.from }, scrollIntoView: true });
          view.focus();
        });
      }
    }
    return wrapper;
  }
  ignoreEvent() { return false; }
}

// 目录块 [toc]：块级装饰必须由 StateField 提供；搜索命中标记时临时展开源码。
const tocSearch = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.isUserEvent('select.search') ? true : transaction.selection !== undefined || transaction.docChanged ? false : value,
});

// 目录条目按语法树缓存：同一棵树只提取一次标题，多个 [toc] 与选区引起的重建共用。
const tocEntryCache = new WeakMap<Tree, { level: number; title: string; from: number }[]>();

function tocEntries(state: EditorState) {
  const tree = syntaxTree(state);
  let entries = tocEntryCache.get(tree);
  if (entries === undefined) {
    entries = headings(state, tree).map(heading => ({ level: heading.level, title: heading.title, from: heading.from }));
    tocEntryCache.set(tree, entries);
  }
  return entries;
}

function tocDecorations(state: EditorState) {
  if (state.field(sourceMode)) return Decoration.none;
  const ranges: Range<Decoration>[] = [];
  const selection = state.selection.main;
  for (const node of topBlocks(state).toc) {
    if (selectionTouches(state, node.from, node.to, true)
      || (state.field(tocSearch) && selection.from < node.to && selection.to > node.from)) continue;
    ranges.push(Decoration.replace({ block: true, widget: new TableOfContents(tocEntries(state)) }).range(state.doc.lineAt(node.from).from, state.doc.lineAt(node.to).to));
  }
  return Decoration.set(ranges, true);
}

const tocBlocks = StateField.define<DecorationSet>({
  create: tocDecorations,
  update: (value, transaction) => transaction.docChanged || transaction.reconfigured
    || transaction.startState.field(sourceMode) !== transaction.state.field(sourceMode)
    || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
    || (transaction.selection !== undefined && !selectionMissesBlocks(transaction, blocks => blocks.toc)) ? tocDecorations(transaction.state) : value,
  provide: field => EditorView.decorations.from(field),
});

export const gfmEditing = [
  tocSearch, tocBlocks,
  EditorView.atomicRanges.of(view => view.state.field(tocBlocks)),
  EditorView.theme({
    '.cm-inkpot-footnote-ref': { fontSize: '0.75em', verticalAlign: 'super', cursor: 'help' },
    '.cm-inkpot-toc': { border: '1px solid rgba(128, 128, 128, 0.35)', borderRadius: '6px', padding: '10px 14px', margin: '10px 0' },
    '.cm-inkpot-toc-item': { cursor: 'pointer', padding: '2px 0', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' },
    '.cm-inkpot-toc-empty': { opacity: 0.7 },
  }),
];
