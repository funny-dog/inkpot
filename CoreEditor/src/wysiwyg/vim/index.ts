import { Compartment } from '@codemirror/state';
import { ViewPlugin } from '@codemirror/view';
import { tryGetEditor } from '../../common/utils';

const compartment = new Compartment;
let revision = 0;

export function vimModeExtension() {
  return [compartment.of([]), ViewPlugin.define(() => {
    if (window.config.vimMode === true) {
      queueMicrotask(() => { if (window.config.vimMode === true) void setVimMode(true); });
    }
    return {};
  })];
}

export async function setVimMode(enabled: boolean) {
  const change = ++revision;
  window.config.vimMode = enabled;
  const extension = enabled ? (await import('@replit/codemirror-vim')).vim() : [];
  if (change === revision) {
    tryGetEditor()?.dispatch({ effects: compartment.reconfigure(extension) });
  }
}
