// 移植自 MarkEdit-preview（https://github.com/MarkEdit-app/MarkEdit-preview）src/hiddenSyntax，上游提交 0dcde1c
// Copyright (c) 2025 MarkEdit.app，MIT License

import { WidgetType } from '@codemirror/view';
import { resolveImageURL } from '../../image';

export class InlineImageWidget extends WidgetType {
  constructor(
    private readonly destination: string,
    private readonly label: string,
  ) {
    super();
  }

  toDOM() {
    const image = document.createElement('img');
    image.className = 'cm-md-syntaxHiddenImage';
    image.src = resolveImageURL(this.destination);
    image.alt = this.label;
    image.title = this.destination;
    image.draggable = false;
    image.loading = 'lazy';
    image.decoding = 'async';
    return image;
  }

  eq(other: InlineImageWidget) {
    return other.destination === this.destination && other.label === this.label;
  }

  ignoreEvent() {
    return false;
  }
}
