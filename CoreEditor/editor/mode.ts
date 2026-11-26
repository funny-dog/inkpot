import { StateEffect, StateField } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

export const setPreviewExport = StateEffect.define<boolean>();
export const previewExport = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.find(effect => effect.is(setPreviewExport))?.value ?? value,
});

export const setSourceMode = StateEffect.define<boolean>();
export const sourceMode = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.find(effect => effect.is(setSourceMode))?.value ?? value,
});

/** 共享的搜索选中态：搜索命中隐藏标记时临时展开源码，表格/公式/目录块共用。 */
export const searchSelection = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.isUserEvent('select.search') ? true : transaction.selection !== undefined || transaction.docChanged ? false : value,
});

/** 跨平台主快捷键修饰键：Windows 用 Ctrl，macOS 用 Cmd；无平台标识的测试环境兼容两者。 */
export function isPrimaryModifier(event: MouseEvent | KeyboardEvent) {
  const platform = typeof navigator !== 'undefined' ? (navigator.platform || navigator.userAgent) : '';
  if (/(?:^|\W)(?:Win32|Win64|Windows)(?:\W|$)/i.test(platform)) return event.ctrlKey && !event.metaKey;
  if (/Mac|iPhone|iPad|iPod/i.test(platform)) return event.metaKey && !event.ctrlKey;
  return event.metaKey || event.ctrlKey;
}

export function isComposing(view: EditorView) {
  return view.compositionStarted || view.dom.querySelector('[data-table-composing]') !== null;
}

export function toggleSourceMode(view: EditorView) {
  if (isComposing(view)) return false;
  view.dispatch({ effects: setSourceMode.of(!view.state.field(sourceMode)) });
  return true;
}
