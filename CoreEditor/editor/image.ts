import { t } from './localization';
import { EditorState, Range, StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { SyntaxNode } from '@lezer/common';
import { linkDestination, selectionTouches } from './basic';
import { imageBase } from './bridge';
import { previewExport } from './mode';

let documentGeneration = 0;
export const setRemoteImages = StateEffect.define<boolean>();
export const remoteImages = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.find(effect => effect.is(setRemoteImages))?.value ?? value,
});
export const refreshImages = StateEffect.define();
export const imageRevision = StateField.define({
  create: () => 0,
  update: (revision, transaction) => transaction.effects.some(effect => effect.is(refreshImages) || effect.is(setRemoteImages)) ? revision + 1 : revision,
});
export function setImageDocument(generation: number) { documentGeneration = generation; }

class ImagePreview extends WidgetType {
  constructor(private readonly path: string, private readonly alt: string,
    private readonly document: number, private readonly revision: number) { super(); }
  // 比较不含绝对文档偏移，前文编辑时不触发后方全部图片重新挂载与闪烁。
  eq(other: ImagePreview) {
    return this.path === other.path && this.alt === other.alt
      && this.document === other.document && this.revision === other.revision;
  }
  toDOM(view: EditorView) {
    const span = document.createElement('span');
    span.className = 'cm-inkpot-image';
    span.title = t('双击图片编辑 Markdown 路径');
    const image = document.createElement('img');
    image.alt = this.alt || t('图片');
    image.src = `${imageBase}${encodeURIComponent(this.path)}?document=${this.document}&revision=${this.revision}`;
    image.addEventListener('load', () => { if (span.isConnected) view.requestMeasure(); });
    image.addEventListener('error', () => {
      if (!span.isConnected) return;
      image.alt = t('图片无法读取：{0}', this.alt || this.path);
      span.title = t('图片无法读取，双击修改路径');
      view.requestMeasure();
    });
    span.append(image);
    span.addEventListener('dblclick', event => {
      if (view.compositionStarted || !span.isConnected) return;
      event.preventDefault();
      const pos = view.posAtDOM(span);
      let node: SyntaxNode | null = syntaxTree(view.state).resolveInner(pos, 1);
      while (node !== null && node.name !== 'Image') node = node.parent;
      if (node !== null) {
        view.dispatch({ selection: { anchor: node.from, head: node.to } });
        view.focus();
      }
    });
    return span;
  }
  ignoreEvent() { return false; }
}

export function imageDecorations(node: SyntaxNode, state: EditorState) {
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  if (state.field(previewExport, false) !== true && selectionTouches(state, node.from, node.to, true)) return { decorations, atoms };
  const path = linkDestination(node, state);
  if (path === undefined || path.startsWith('//')) return { decorations, atoms };
  if (/^[a-z][a-z\d+.-]*:/i.test(path) && !/^file:/i.test(path)) {
    if (state.field(remoteImages, false) !== true) return { decorations, atoms };
    try {
      const url = new URL(path);
      if (url.protocol !== 'https:' || url.username !== '' || url.password !== '') return { decorations, atoms };
    } catch { return { decorations, atoms }; }
  }
  const marks = node.getChildren('LinkMark');
  const alt = state.sliceDoc(marks[0]?.to ?? node.from, marks[1]?.from ?? node.to);
  const range = Decoration.replace({ widget: new ImagePreview(path, alt, documentGeneration, state.field(imageRevision)) }).range(node.from, node.to);
  decorations.push(range);
  atoms.push(range);
  return { decorations, atoms };
}
