import { EditorState, Range, StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, WidgetType } from '@codemirror/view';
import { SyntaxNode } from '@lezer/common';
import { linkDestination, selectionTouches } from './basic';

let documentGeneration = 0;
export const refreshImages = StateEffect.define();
export const imageRevision = StateField.define({
  create: () => 0,
  update: (revision, transaction) => transaction.effects.some(effect => effect.is(refreshImages)) ? revision + 1 : revision,
});
export function setImageDocument(generation: number) { documentGeneration = generation; }

class ImagePreview extends WidgetType {
  constructor(private readonly path: string, private readonly alt: string, private readonly from: number, private readonly to: number,
    private readonly document: number, private readonly revision: number) { super(); }
  eq(other: ImagePreview) {
    return this.path === other.path && this.alt === other.alt && this.from === other.from && this.to === other.to
      && this.document === other.document && this.revision === other.revision;
  }
  toDOM(view: EditorView) {
    const span = document.createElement('span');
    span.className = 'cm-mvp-image';
    span.title = '双击图片编辑 Markdown 路径';
    const image = document.createElement('img');
    image.alt = this.alt || '图片';
    image.src = `inkpot-image://local/${encodeURIComponent(this.path)}?document=${this.document}&revision=${this.revision}`;
    image.addEventListener('load', () => view.requestMeasure());
    image.addEventListener('error', () => {
      image.alt = `图片无法读取：${this.alt || this.path}`;
      span.title = '图片无法读取，双击修改路径';
      view.requestMeasure();
    });
    span.append(image);
    span.addEventListener('dblclick', event => {
      if (view.compositionStarted) return;
      event.preventDefault();
      view.dispatch({ selection: { anchor: this.from, head: this.to } });
      view.focus();
    });
    return span;
  }
  ignoreEvent() { return false; }
}

export function imageDecorations(node: SyntaxNode, state: EditorState) {
  const decorations: Range<Decoration>[] = [];
  const atoms: Range<Decoration>[] = [];
  if (selectionTouches(state, node.from, node.to, true)) return { decorations, atoms };
  const path = linkDestination(node, state);
  if (path === undefined || /^(?!file:)[a-z][a-z\d+.-]*:/i.test(path) || path.startsWith('//')) return { decorations, atoms };
  const marks = node.getChildren('LinkMark');
  const alt = state.sliceDoc(marks[0]?.to ?? node.from, marks[1]?.from ?? node.to);
  const range = Decoration.replace({ widget: new ImagePreview(path, alt, node.from, node.to, documentGeneration, state.field(imageRevision)) }).range(node.from, node.to);
  decorations.push(range);
  atoms.push(range);
  return { decorations, atoms };
}
