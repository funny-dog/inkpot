import { ensureSyntaxTree } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';

/**
 * 根据 `#anchor` 找到对应标题所在的行号（从 0 开始）。
 *
 * 预览扩展用 markdown-it 解析，这里改用编辑器已有的 Lezer 语法树，slug 规则保持一致。
 */
export function headingLineForAnchor(state: EditorState, destination: string) {
  if (!destination.startsWith('#')) {
    return undefined;
  }

  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  if (tree === null) {
    return undefined;
  }

  const target = normalizeAnchor(destination.substring(1));
  let line: number | undefined;
  tree.iterate({
    enter: node => {
      if (line !== undefined) {
        return false;
      }

      if (!/^(ATXHeading|SetextHeading)\d$/.test(node.name)) {
        return;
      }

      const firstLine = state.doc.lineAt(node.from);
      const title = node.name.startsWith('ATX')
        ? firstLine.text.replace(/^ {0,3}#+ +/, '').replace(/ +#+ *$/, '')
        : firstLine.text.trim();

      if (normalizeAnchor(slugify(title)) === target) {
        line = firstLine.number - 1;
      }

      return false;
    },
  });

  return line;
}

export function slugify(title: string) {
  return (title.length > 64 ? title.substring(0, 64) + '...' : title)
    .normalize('NFKD')
    .trim()
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}\s\-_]/gu, '')
    .replace(/\s+/g, '-');
}

function normalizeAnchor(anchor: string) {
  try {
    return decodeURIComponent(anchor).toLowerCase();
  } catch {
    return anchor.toLowerCase();
  }
}
