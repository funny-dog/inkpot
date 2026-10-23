import { EditorView } from '@codemirror/view';
import { sourceMode, toggleSourceMode } from './mode';
import { applyAppearance } from './theme';

const exportCSS = `
body { font: 16px/1.7 -apple-system, 'PingFang SC', 'Hiragino Sans GB', sans-serif; color: #202020; background: #fff; margin: 0 auto; padding: 32px 28px; max-width: 740px; }
.inkpot-export { white-space: pre-wrap; overflow-wrap: anywhere; }
.inkpot-export .cm-line { min-height: 1.7em; padding: 0 2px; }
img { max-width: 100%; }
.cm-mvp-image { display: inline-block; max-width: 100%; }
.cm-mvp-inline-code { font-family: Menlo, monospace; border-radius: 3px; padding: 1px 4px; }
.cm-mvp-code { background: #f4f5f7; font-family: Menlo, monospace; padding: 1px 12px; }
.cm-mvp-code-header { border-radius: 6px 6px 0 0; padding-top: 6px; font-size: 13px; }
.cm-mvp-code-footer { border-radius: 0 0 6px 6px; padding-bottom: 6px; }
table { border-collapse: collapse; width: 100%; table-layout: fixed; margin: 12px 0; }
th, td { border: 1px solid #c6cbd1; padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: #f4f5f6; }
blockquote, .cm-mvp-quote { border-left: 3px solid #c6cbd1; color: #5f6368; padding-left: 12px; margin: 8px 0; }
.cm-mvp-rule { display: block; border-top: 1px solid #c6cbd1; margin: 12px 0; }
.cm-mvp-toc { border: 1px solid rgba(128, 128, 128, 0.35); border-radius: 6px; padding: 10px 14px; margin: 10px 0; }
.cm-mvp-toc-item { padding: 2px 0; }
.cm-mvp-math-block { display: block; text-align: center; margin: 10px 0; padding: 6px 0; overflow-x: auto; }
.katex { font-size: 1.1em; }
`;

/** 导出用的独立 HTML 文档：基于实时视图序列化，配色固定浅色，不依赖编辑器运行时。 */
export function documentHTML(view: EditorView, mode: 'html' | 'pdf' = 'html'): string {
  // 序列化以实时视图为准；记录并恢复调用前的源码模式、光标与外观（导出固定浅色）。
  const wasSource = view.state.field(sourceMode);
  const selection = view.state.selection;
  const wasDark = view.dom.matches('.cm-mvp-dark');
  if (wasSource) toggleSourceMode(view);
  if (wasDark) applyAppearance(view, false);
  view.dispatch({ selection: { anchor: 0 } });
  const clone = view.contentDOM.cloneNode(true) as HTMLElement;
  view.dispatch({ selection });
  if (wasDark) applyAppearance(view, true);
  if (wasSource) toggleSourceMode(view);

  clone.removeAttribute('contenteditable');
  clone.removeAttribute('spellcheck');
  clone.removeAttribute('aria-label');
  clone.removeAttribute('autocorrect');
  clone.className = 'inkpot-export';
  for (const element of [...clone.querySelectorAll('.cm-mvp-table-input, .cm-mvp-table-hint, .cm-mvp-hidden-inline, .cm-cursor, .cm-dropCursor, .cm-selectionBackground')]) {
    element.remove();
  }

  // 语法加粗、删除线、高亮等来自语法高亮类，导出文档没有对应样式表，内联关键计算样式。
  const originals = view.contentDOM.querySelectorAll<HTMLElement>('*');
  const copies = clone.querySelectorAll<HTMLElement>('*');
  originals.forEach((original, index) => {
    if (index >= copies.length) return;
    const copy = copies[index];
    // MathML 等外来元素没有 style 属性，其样式由公式自身的渲染承担。
    if (!(original instanceof HTMLElement) || !(copy instanceof HTMLElement)) return;
    const source = getComputedStyle(original) as unknown as Record<string, string>;
    const parent = original.parentElement === null ? source : getComputedStyle(original.parentElement) as unknown as Record<string, string>;
    for (const property of ['fontWeight', 'fontStyle', 'textDecorationLine', 'backgroundColor', 'color', 'verticalAlign', 'fontSize'] as const) {
      const value = source[property];
      if (value !== '' && value !== 'inherit' && value !== parent[property]) copy.style[property] = value;
    }
  });

  // 复选框的选中态是运行时属性，克隆与序列化都会丢失，按原件写回属性。
  const sourceBoxes = view.contentDOM.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
  const boxes = clone.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
  for (let index = 0; index < boxes.length && index < sourceBoxes.length; index++) {
    if (sourceBoxes[index].checked) boxes[index].setAttribute('checked', '');
    boxes[index].disabled = true;
  }

  // 本地图片还原为相对路径：导出 HTML 与文档放在一起时可显示，PDF 通过 baseURL 解析。
  for (const image of clone.querySelectorAll<HTMLImageElement>('img')) {
    try {
      const url = new URL(image.getAttribute('src') ?? '');
      if (url.host === 'local') image.setAttribute('src', decodeURIComponent(url.pathname.slice(1)));
    } catch { /* 非 URL 的 src 原样保留 */ }
  }

  if (mode === 'html') {
    // 独立 HTML 无 KaTeX 样式：保留浏览器原生渲染的 MathML，去掉依赖样式的排版副本。
    for (const element of [...clone.querySelectorAll('.katex')]) {
      const mathml = element.querySelector('.katex-mathml');
      const math = mathml?.firstElementChild;
      if (math !== undefined && math !== null) {
        math.removeAttribute('aria-hidden');
        element.replaceChildren(math);
      }
    }
  }

  const firstLine = view.state.doc.line(1).text.trim();
  const title = firstLine.length > 0 ? firstLine.replace(/^#+\s*/, '').slice(0, 60) : '文档';
  const katex = mode === 'pdf' ? '<link rel="stylesheet" href="inkpot-asset://math/katex.min.css">\n' : '';
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(title)}</title>
${katex}<style>${exportCSS}</style>
</head>
<body>
${clone.innerHTML}
</body>
</html>`;
}

function escapeHTML(text: string) {
  return text.replace(/[&<>"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[char] ?? char);
}
