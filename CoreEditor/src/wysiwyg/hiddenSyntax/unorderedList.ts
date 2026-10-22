// 移植自 MarkEdit-preview（https://github.com/MarkEdit-app/MarkEdit-preview）src/hiddenSyntax，上游提交 0dcde1c
// Copyright (c) 2025 MarkEdit.app，MIT License

import type { EditorState } from '@codemirror/state';
import type { SyntaxNodeRef } from '@lezer/common';
import { selectionReveals } from './selection';

export function unorderedListSyntax(node: SyntaxNodeRef, state: EditorState) {
  if (node.name !== 'ListMark') {
    return;
  }

  const item = node.node.parent;
  const task = item?.getChild('Task');
  const taskMarker = task?.getChild('TaskMarker');
  if (
    item?.name !== 'ListItem'
    || item.parent?.name !== 'BulletList'
    || !/^[ \t]$/.test(state.sliceDoc(node.to, node.to + 1))
    || selectionReveals(state, node.from, taskMarker?.to ?? node.to)
  ) {
    return;
  }

  return {
    from: node.from,
    to: node.to,
    task: task !== null,
  };
}
