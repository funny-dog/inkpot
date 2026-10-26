import { t } from './localization';
import { EditorState, Range, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { Decoration, DecorationSet, EditorView, WidgetType } from '@codemirror/view';
import { selectionTouches } from './basic';
import { selectionMissesBlocks, topBlocks } from './blocks';
import { isComposing, previewExport, sourceMode } from './mode';
import { assetBase } from './bridge';

type Mermaid = Pick<typeof import('mermaid').default, 'initialize' | 'render'>;
let load = async (): Promise<Mermaid> => (await import(/* @vite-ignore */ `${assetBase}mermaid.mjs`) as { default: Mermaid }).default;
let library: Promise<Mermaid> | undefined;
let renderTail: Promise<void> = Promise.resolve();
let diagramID = 0;

export function useMermaidForTests(module: Mermaid) {
  library = undefined;
  load = () => Promise.resolve(module);
}

async function render(source: string, dark: boolean, element: HTMLElement) {
  const previous = renderTail;
  const job = (async () => {
    await previous;
    if (!element.isConnected) return '';
    try {
      const mermaid = await (library ??= load());
      // 文档配置不能放宽执行边界或覆盖资源限制；SVG 文本也便于独立导出。
      mermaid.initialize({
        startOnLoad: false, securityLevel: 'strict', htmlLabels: false, suppressErrorRendering: true,
        maxTextSize: 50000, maxEdges: 500, theme: dark ? 'dark' : 'default', layout: 'dagre',
        fontFamily: 'system-ui, sans-serif',
        secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'htmlLabels', 'theme', 'themeCSS', 'fontFamily', 'layout', 'dompurifyConfig'],
      });
      const staging = document.body.appendChild(document.createElement('div'));
      staging.style.cssText = 'position:absolute;visibility:hidden;pointer-events:none';
      try { return (await mermaid.render(`inkpot-diagram-${++diagramID}`, source, staging)).svg; } finally { staging.remove(); }
    } catch (error) {
      library = undefined;
      throw error;
    }
  })();
  // Mermaid 的配置和布局共享状态，串行渲染避免多个图表或主题切换相互覆盖。
  renderTail = (async () => { try { await job; } catch { /* 失败不阻塞后续图表。 */ } })();
  return job;
}

class MermaidPreview extends WidgetType {
  constructor(readonly source: string, readonly anchor: number, readonly dark: boolean) { super(); }
  eq(other: MermaidPreview) { return this.source === other.source && this.anchor === other.anchor && this.dark === other.dark; }

  toDOM(view: EditorView) {
    const element = document.createElement('div');
    element.className = 'cm-inkpot-mermaid';
    element.textContent = this.source;
    element.setAttribute('aria-label', t('Mermaid 图表：{0}', this.source.slice(0, 100)));
    const editable = !view.state.readOnly && view.state.facet(EditorView.editable);
    element.setAttribute('role', editable ? 'button' : 'img');
    if (editable) {
      element.tabIndex = 0;
      element.title = t('点击或按 Enter 编辑图表源码');
    }
    const reveal = () => {
      if (!editable || isComposing(view)) return;
      view.dispatch({ selection: { anchor: this.anchor }, scrollIntoView: true });
      view.focus();
    };
    element.addEventListener('mousedown', event => { if (event.button === 0) { event.preventDefault(); reveal(); } });
    element.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); reveal(); } });
    element.dataset.renderPending = '';
    void (async () => {
      try {
        if (this.source.length > 50000) throw new Error(t('图表文本超过 50,000 字符限制'));
        const svg = await render(this.source, this.dark, element);
        if (element.isConnected) {
          element.innerHTML = svg;
          const drawing = element.querySelector('svg');
          const parts = drawing?.getAttribute('viewBox')?.split(/\s+/).map(Number) ?? [];
          const [, , svgW, svgH] = parts;
          if (drawing !== null && svgW > 0) {
            // 以容器实际像素宽度为上限，超宽时按比例缩小；
            // 不依赖百分比 CSS（contain:inline-size 下基准异常）。
            const containerW = element.clientWidth;
            if (containerW > 0 && svgW > containerW) {
              drawing.setAttribute('width', String(containerW));
              if (svgH > 0) drawing.setAttribute('height', String(Math.round(containerW / svgW * svgH)));
            } else {
              drawing.setAttribute('width', String(svgW));
            }
            drawing.style.maxWidth = 'none';
          }
        }
      } catch {
        if (element.isConnected) {
          element.classList.add('cm-inkpot-mermaid-error');
          element.textContent = t('图表暂时无法显示，请编辑源码检查语法或简化图表。\n{0}', this.source);
        }
      } finally {
        delete element.dataset.renderPending;
        if (element.isConnected) view.requestMeasure();
      }
    })();
    return element;
  }
  ignoreEvent() { return false; }
}

function decorations(state: EditorState) {
  const exporting = state.field(previewExport, false) === true;
  if (state.field(sourceMode) && !exporting) return Decoration.none;
  const ranges: Range<Decoration>[] = [];
  for (const node of topBlocks(state).mermaid) {
    const info = node.getChild('CodeInfo');
    const marks = node.getChildren('CodeMark');
    if (info === null || marks.length !== 2) continue;
    if (!exporting && selectionTouches(state, node.from, node.to, true)) continue;
    const start = state.doc.lineAt(info.to).to + 1;
    const source = state.sliceDoc(start, marks[1].from).trim();
    if (source === '') continue;
    const from = state.doc.lineAt(node.from).from;
    const to = state.doc.lineAt(node.to).to;
    ranges.push(Decoration.replace({ block: true, widget: new MermaidPreview(source, start, !exporting && state.facet(EditorView.darkTheme)) }).range(from, to));
  }
  return Decoration.set(ranges, true);
}

const mermaidBlocks = StateField.define<DecorationSet>({
  create: decorations,
  update: (value, transaction) => transaction.docChanged || transaction.reconfigured
    || transaction.effects.length > 0 || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)
    || (transaction.selection !== undefined && !selectionMissesBlocks(transaction, blocks => blocks.mermaid))
    ? decorations(transaction.state) : value,
  provide: field => EditorView.decorations.from(field),
});

export function hasMermaidPreview(state: EditorState, from: number) {
  let found = false;
  state.field(mermaidBlocks).between(state.doc.lineAt(from).from, from + 1, () => { found = true; });
  return found;
}

export const mermaidEditing = [mermaidBlocks, EditorView.atomicRanges.of(view => view.state.field(mermaidBlocks)),
  EditorView.theme({
    '.cm-inkpot-mermaid': { display: 'block', padding: '12px 0', overflowX: 'auto', contain: 'inline-size', textAlign: 'center', whiteSpace: 'normal' },
    '.cm-inkpot-mermaid[tabindex]': { cursor: 'pointer' },
    '.cm-inkpot-mermaid svg': { maxWidth: '100%', height: 'auto' },
    '.cm-inkpot-mermaid-error': { whiteSpace: 'pre-wrap', textAlign: 'left', color: '#b3261e' },
    '&.cm-inkpot-dark .cm-inkpot-mermaid-error': { color: '#e8736a' },
  }),
];
