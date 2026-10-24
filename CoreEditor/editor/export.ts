import { ensureSyntaxTree, syntaxParserRunning, syntaxTree } from '@codemirror/language';
import { EditorView } from '@codemirror/view';
import { isComposing, previewExport, setPreviewExport, sourceMode, toggleSourceMode } from './mode';
import { applyAppearance } from './theme';
import { loadDocumentLanguages } from './code-languages';

const exportCSS = `
body { font: 16px/1.7 -apple-system, 'PingFang SC', 'Hiragino Sans GB', sans-serif; color: #202020; background: #fff; margin: 0 auto; padding: 32px 28px; max-width: 740px; }
.inkpot-export { overflow-wrap: anywhere; }
.inkpot-export .cm-line { min-height: 1.7em; padding: 0 2px; }
.inkpot-export p { margin: 0; }
img { max-width: 100%; }
.cm-inkpot-image { display: inline-block; max-width: 100%; }
.cm-inkpot-inline-code { font-family: Menlo, monospace; border-radius: 3px; padding: 1px 4px; white-space: pre-wrap; }
.cm-inkpot-code { background: #f4f5f7; font-family: Menlo, monospace; padding: 1px 12px; white-space: pre-wrap; }
.cm-inkpot-code-header { border-radius: 6px 6px 0 0; padding-top: 6px; font-size: 13px; }
.cm-inkpot-code-footer { border-radius: 0 0 6px 6px; padding-bottom: 6px; }
table { border-collapse: collapse; width: 100%; table-layout: fixed; margin: 12px 0; }
th, td { border: 1px solid #c6cbd1; padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: #f4f5f6; }
blockquote, .cm-inkpot-quote { border-left: 3px solid #c6cbd1; color: #5f6368; padding-left: 12px; margin: 8px 0; }
.cm-inkpot-rule { display: block; border-top: 1px solid #c6cbd1; margin: 12px 0; }
.cm-inkpot-toc { border: 1px solid rgba(128, 128, 128, 0.35); border-radius: 6px; padding: 10px 14px; margin: 10px 0; }
.cm-inkpot-toc-item { padding: 2px 0; }
.cm-inkpot-math-block { display: block; text-align: center; margin: 10px 0; padding: 6px 0; overflow-x: auto; }
.katex { font-size: 1.1em; }
.cm-inkpot-mermaid { display: block; text-align: center; overflow-x: auto; padding: 12px 0; white-space: normal; }
.cm-inkpot-mermaid svg { max-width: 100%; height: auto; }
.cm-inkpot-mermaid-error { white-space: pre-wrap; text-align: left; }
@media print {
  body { max-width: none; padding: 0; }
  .cm-line, tr, img, .cm-inkpot-image, .cm-inkpot-math-block, .cm-inkpot-mermaid, .cm-inkpot-toc { break-inside: avoid; }
  .cm-inkpot-heading1, .cm-inkpot-heading2, .cm-inkpot-heading3, .cm-inkpot-heading4, .cm-inkpot-heading5, .cm-inkpot-heading6, .cm-inkpot-code-header { break-after: avoid; }
  thead { display: table-header-group; }
}
`;

/** 只在导出副本中合并同一 Markdown 段落的软换行，代码与显式硬换行保持原样。 */
function exportParagraphs(view: EditorView, clone: HTMLElement) {
  const originals = Array.from(view.contentDOM.children);
  const copies = Array.from(clone.children);
  let paragraph: HTMLElement | undefined;
  let paragraphFrom = -1;
  let previousHardBreak = false;
  originals.forEach((line, index) => {
    const copy = copies[index];
    if (!(copy instanceof HTMLElement) || !line.matches('.cm-line') || line.matches('.cm-inkpot-code')) {
      paragraph = undefined;
      return;
    }
    const position = view.posAtDOM(line, 0);
    const sourceLine = view.state.doc.lineAt(position);
    let node = syntaxTree(view.state).resolveInner(position, 1);
    while (node.name !== 'Paragraph' && node.parent !== null) node = node.parent;
    if (node.name !== 'Paragraph') { paragraph = undefined; return; }
    if (paragraph === undefined || paragraphFrom !== node.from) {
      paragraph = document.createElement('p');
      paragraph.className = copy.className;
      paragraph.style.cssText = copy.style.cssText;
      copy.replaceWith(paragraph);
      paragraphFrom = node.from;
    } else {
      paragraph.append(previousHardBreak ? document.createElement('br') : document.createTextNode('\n'));
      copy.remove();
    }
    if (/(?:^|[^\\])(?:\\\\)*\\$/.test(sourceLine.text)) {
      const walker = document.createTreeWalker(copy, NodeFilter.SHOW_TEXT);
      let last: Node | null = null;
      while (walker.nextNode()) last = walker.currentNode;
      if (last !== null && last.textContent?.endsWith('\\') === true) last.textContent = last.textContent.slice(0, -1);
    }
    paragraph.append(...Array.from(copy.childNodes));
    previousHardBreak = / {2,}$/.test(sourceLine.text) || /(?:^|[^\\])(?:\\\\)*\\$/.test(sourceLine.text);
  });
}

/** 图片内嵌后，HTML 和 PDF 不依赖原文件夹；失败时中止，不能悄悄交付缺图文档。 */
async function embedImages(clone: HTMLElement) {
  const embedded = new Map<string, string>();
  let total = 0;
  for (const image of clone.querySelectorAll<HTMLImageElement>('img')) {
    const source = image.getAttribute('src') ?? '';
    if (!source.startsWith('inkpot-image://local/')) throw new Error('图片来源不受支持，已取消导出。');
    let dataURL = embedded.get(source);
    if (dataURL === undefined) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 20000);
      try {
        const response = await fetch(source, { signal: controller.signal });
        if (!response.ok) throw new Error('图片无法读取');
        const blob = await response.blob();
        total += blob.size;
        if (blob.size > 20 * 1024 * 1024 || total > 50 * 1024 * 1024) throw new Error('图片体积超过导出限制（单张 20 MB，总计 50 MB）');
        dataURL = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => typeof reader.result === 'string' ? resolve(reader.result) : reject(new Error('图片编码失败'));
          reader.onerror = () => reject(new Error('图片编码失败'));
          reader.readAsDataURL(blob);
        });
        embedded.set(source, dataURL);
      } catch (error) {
        throw new Error(`无法导出图片“${image.alt || '图片'}”：${error instanceof Error ? error.message : '读取失败'}`);
      } finally { clearTimeout(timer); }
    }
    image.src = dataURL;
  }
}

/** 导出用的独立 HTML 文档：基于实时视图序列化，配色固定浅色，不依赖编辑器运行时。 */
export async function documentHTML(view: EditorView, mode: 'html' | 'pdf' = 'html'): Promise<string> {
  if (isComposing(view)) throw new Error('请先确认输入法候选文字，再导出。');
  if (view.state.field(previewExport)) throw new Error('正在导出，请等待完成。');
  const original = view.state.doc;
  if (ensureSyntaxTree(view.state, original.length, 100) === null) throw new Error('文档尚未完成解析，请稍后重试导出。');
  // 序列化以实时视图为准；记录并恢复调用前的源码模式、光标与外观（导出固定浅色）。
  const wasSource = view.state.field(sourceMode);
  const selection = view.state.selection;
  const wasDark = view.dom.matches('.cm-inkpot-dark');
  let clone: HTMLElement;
  // shortcut: CodeMirror 尚无公开的全篇 DOM 导出接口，升级编辑器依赖时需复验内部打印布局。
  const printLayout = () => (view as unknown as { observer: { onPrint(event: Event): void } }).observer.onPrint(new Event('beforeprint'));
  const timer = setInterval(printLayout, 250);
  try {
    if (wasSource) toggleSourceMode(view);
    if (wasDark) applyAppearance(view, false);
    view.dispatch({ selection: { anchor: 0 }, effects: setPreviewExport.of(true) });
    printLayout();
    const deadline = Date.now() + 10000;
    // 代码语言文件按需加载，加载后等待重新解析，使导出与编辑器着色一致。
    const languagesLoaded = await loadDocumentLanguages();
    while ((languagesLoaded && syntaxParserRunning(view)) || view.dom.querySelector('[data-render-pending]') !== null
      || view.dom.querySelectorAll('.cm-inkpot-math:not(.cm-inkpot-math-error) .katex').length
        !== view.dom.querySelectorAll('.cm-inkpot-math:not(.cm-inkpot-math-error)').length) {
      if (!view.dom.isConnected || view.state.doc !== original) throw new Error('文档已关闭或导出期间发生编辑，请重新导出。');
      if (Date.now() > deadline) throw new Error('图表或公式渲染超时，请检查内容后重试。');
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    if (view.state.doc !== original) throw new Error('导出期间发生编辑，请重新导出。');
    clone = view.contentDOM.cloneNode(true) as HTMLElement;

    clone.removeAttribute('contenteditable');
    clone.removeAttribute('spellcheck');
    clone.removeAttribute('aria-label');
    clone.removeAttribute('autocorrect');
    clone.className = 'inkpot-export';

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

    for (const diagram of clone.querySelectorAll('.cm-inkpot-mermaid')) {
      diagram.removeAttribute('tabindex'); diagram.removeAttribute('title');
      const svg = diagram.querySelector('svg');
      svg?.style.removeProperty('max-width');
      svg?.setAttribute('width', '100%');
    }

    for (const element of [...clone.querySelectorAll('.cm-inkpot-table-input, .cm-inkpot-table-hint, .cm-inkpot-hidden-inline, .cm-widgetBuffer, .cm-cursor, .cm-dropCursor, .cm-selectionBackground')]) {
      element.remove();
    }

    // 专注模式的淡化只在编辑器视口内生效，导出与打印不携带。
    for (const element of clone.querySelectorAll('.cm-focus-dim')) element.classList.remove('cm-focus-dim');

    // 复选框的选中态是运行时属性，克隆与序列化都会丢失，按原件写回属性。
    const sourceBoxes = view.contentDOM.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
    const boxes = clone.querySelectorAll<HTMLInputElement>('input[type="checkbox"]');
    for (let index = 0; index < boxes.length && index < sourceBoxes.length; index++) {
      if (sourceBoxes[index].checked) boxes[index].setAttribute('checked', '');
      boxes[index].disabled = true;
    }

    exportParagraphs(view, clone);
    await embedImages(clone);
    if (!view.dom.isConnected || view.state.doc !== original) throw new Error('导出期间发生编辑或文档已关闭，请重新导出。');

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
  } finally {
    clearInterval(timer);
    if (view.dom.isConnected) {
      view.dispatch({ effects: setPreviewExport.of(false), ...(view.state.doc === original ? { selection } : {}) });
      if (wasDark) applyAppearance(view, true);
      if (wasSource && !view.state.field(sourceMode)) toggleSourceMode(view);
    }
  }

}

function escapeHTML(text: string) {
  return text.replace(/[&<>"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[char] ?? char);
}
