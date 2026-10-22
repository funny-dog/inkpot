import { Compartment } from '@codemirror/state';
import { hiddenSyntaxExtension } from './hiddenSyntax';
import { tryGetEditor } from '../common/utils';
import { renderedBlocks, renderTheme } from './render';
import { interactiveTables } from './tables';
import { richPaste } from './paste';

declare module 'markedit-api' {
  interface EditorConfig {
    liveMode?: boolean;
    vimMode?: boolean;
  }
}

// 实时模式（所见即所得）：通过 Compartment 动态开关，不改动文档内容
const liveModeCompartment = new Compartment;
const liveExtensions = () => [hiddenSyntaxExtension, renderedBlocks, renderTheme, interactiveTables(), richPaste];

export function liveModeExtension() {
  return liveModeCompartment.of(window.config.liveMode !== false ? liveExtensions() : []);
}

export function setLiveMode(enabled: boolean) {
  window.config.liveMode = enabled;

  // 编辑器尚未创建时只记录配置，创建时由 liveModeExtension() 读取
  const editor = tryGetEditor();
  if (editor === null) {
    return;
  }

  editor.dispatch({
    effects: liveModeCompartment.reconfigure(enabled ? liveExtensions() : []),
  });
}
