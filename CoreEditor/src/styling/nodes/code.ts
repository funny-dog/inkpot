import { Decoration } from '@codemirror/view';
import { createBlockWrappers, createDecos, createLineDeco } from '../matchers/lezer';
import { createBlockPlugin, createDecoPlugin } from '../helper';

/**
 * Decorations for InlineCode.
 */
export const inlineCodeStyle = createDecoPlugin(() => {
  return createDecos('InlineCode', node => {
    const { from, to } = node;
    if (to - from < 2) {
      // Skip degenerate spans from partial parses
      return null;
    }

    // Tile the range with non-overlapping marks so the boundary class lands on the
    // background element itself, visible spaces only ever split the middle tile
    const base = 'cm-md-monospace cm-md-inlineCode';
    const ranges = [
      Decoration.mark({ class: `${base} cm-md-inlineCodeStart` }).range(from, from + 1),
      Decoration.mark({ class: `${base} cm-md-inlineCodeEnd` }).range(to - 1, to),
    ];

    if (from + 1 < to - 1) {
      ranges.push(Decoration.mark({ class: base }).range(from + 1, to - 1));
    }

    return ranges;
  });
});

/**
 * Always use monospace font for FencedCode and CodeBlock.
 */
export const codeBlockStyle = (() => {
  const nodeNames = ['FencedCode', 'CodeBlock'];
  return [
    createBlockPlugin(() => createBlockWrappers(nodeNames, 'cm-md-codeBlockWrapper', {
      'spellcheck': 'false',
      'autocorrect': 'off',
      'autocomplete': 'off',
      'autocapitalize': 'off',
    })),
    createDecoPlugin(() => createLineDeco(nodeNames, 'cm-md-monospace cm-md-codeBlock')),
  ];
})();
