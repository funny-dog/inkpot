import { syntaxTree } from '@codemirror/language';
import { EditorSelection, EditorState, Text, Transaction } from '@codemirror/state';
import { SyntaxNode, Tree } from '@lezer/common';
import { blockMathTagName } from './math-parser';

export interface TopBlocks {
  math: SyntaxNode[];
  toc: SyntaxNode[];
  mermaid: SyntaxNode[];
  table: SyntaxNode[];
}

// 顶层块索引：公式、目录、图表、表格的块级装饰只出现在文档顶层，语法树变化时沿顶层兄弟节点走一遍即可，
// 不再深入遍历整棵树；同一棵树只收集一次，四个模块共用，光标移动不会触发收集。
const cache = new WeakMap<Tree, { doc: Text; blocks: TopBlocks }>();

export function topBlocks(state: EditorState): TopBlocks {
  const tree = syntaxTree(state);
  const cached = cache.get(tree);
  if (cached?.doc === state.doc) return cached.blocks;
  const blocks: TopBlocks = { math: [], toc: [], mermaid: [], table: [] };
  const cursor = tree.cursor();
  if (cursor.firstChild()) {
    do {
      const name = cursor.name;
      if (name === blockMathTagName) blocks.math.push(cursor.node);
      else if (name === 'Table') blocks.table.push(cursor.node);
      else if (name === 'FencedCode') {
        const node = cursor.node;
        const info = node.getChild('CodeInfo');
        if (info !== null && state.sliceDoc(info.from, info.to).trim() === 'mermaid') blocks.mermaid.push(node);
      } else if (name === 'Paragraph' && cursor.to - cursor.from <= 32
        && state.sliceDoc(cursor.from, cursor.to).trim().toLowerCase() === '[toc]') {
        // 先按长度筛掉普通段落，避免为每个段落截取文本。
        blocks.toc.push(cursor.node);
      }
    } while (cursor.nextSibling());
  }
  cache.set(tree, { doc: state.doc, blocks });
  return blocks;
}

// 与 selectionTouches(…, true) 同一口径：选区与块重叠，或光标严格位于块内部。块按位置排序且互不重叠，用二分查找。
export function selectionTouchesAny(nodes: readonly SyntaxNode[], selection: EditorSelection) {
  return selection.ranges.some(range => {
    const start = range.empty ? range.head : range.from;
    const end = range.empty ? range.head : range.to;
    let low = 0, high = nodes.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (nodes[middle].to > start) high = middle; else low = middle + 1;
    }
    return low < nodes.length && nodes[low].from < end;
  });
}

// 文档与语法树未变、只移动选区时，新旧选区都没碰到候选块就能保留原装饰，不必重建。
export function selectionMissesBlocks(transaction: Transaction, pick: (blocks: TopBlocks) => readonly SyntaxNode[]) {
  const nodes = pick(topBlocks(transaction.state));
  return !selectionTouchesAny(nodes, transaction.startState.selection) && !selectionTouchesAny(nodes, transaction.state.selection);
}
