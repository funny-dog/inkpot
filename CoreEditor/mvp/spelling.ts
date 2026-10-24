import { syntaxTree } from '@codemirror/language';
import { Range } from '@codemirror/state';
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';
import { blockMathTagName } from './math-parser';
import { inlineMathTagName } from './math';
import { isComposing } from './mode';

// 拼写检查只针对正文：代码、公式、HTML、链接地址与引用定义不画拼写下划线。只处理可视区域。
const excluded = new Set([
  'InlineCode', 'FencedCode', 'CodeBlock', 'HTMLBlock', 'HTMLTag', 'CommentBlock', 'Comment', 'ProcessingInstructionBlock',
  'URL', 'Autolink', 'LinkReference', inlineMathTagName, blockMathTagName,
]);
const noSpellcheck = Decoration.mark({ attributes: { spellcheck: 'false' } });

function decorations(view: EditorView): DecorationSet {
  const ranges: Range<Decoration>[] = [];
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(view.state).iterate({ from, to, enter(node) {
      if (!excluded.has(node.name)) return;
      if (node.to > node.from) ranges.push(noSpellcheck.range(node.from, node.to));
      return false;
    } });
  }
  return Decoration.set(ranges, true);
}

export const spellingExclusions = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = decorations(view); }
  update(update: ViewUpdate) {
    // 组合输入期间不改动候选文字周围的 DOM，只映射已有装饰。
    if (isComposing(update.view)) this.decorations = this.decorations.map(update.changes);
    else if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = decorations(update.view);
    }
  }
}, { decorations: plugin => plugin.decorations });
