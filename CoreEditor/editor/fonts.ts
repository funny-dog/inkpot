import { EditorView } from '@codemirror/view';

export type EditorFonts = { bodyFamily: string; bodySize: number; codeFamily: string; codeSize: number };

/** 字体仅影响编辑器显示，不产生文档事务或撤销记录。 */
export function applyFonts(view: EditorView, fonts: EditorFonts) {
  for (const kind of ['body', 'code'] as const) {
    const family = fonts[`${kind}Family`];
    const size = fonts[`${kind}Size`];
    const fallback = kind === 'body' ? 'system-ui, sans-serif' : 'Menlo, monospace';
    view.dom.style.setProperty(`--inkpot-${kind}-font`, family === '' ? fallback : `${JSON.stringify(family)}, ${fallback}`);
    view.dom.style.setProperty(`--inkpot-${kind}-size`, `${Number.isFinite(size) && size >= 8 && size <= 72 ? size : 15}px`);
  }
  view.requestMeasure();
}
