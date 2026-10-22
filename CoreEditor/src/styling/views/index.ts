import { WidgetView } from './types';

/**
 * Widget used to render line breaks as visible characters.
 */
export class LineBreakWidget extends WidgetView {
  constructor(pos: number) {
    super(pos);
  }

  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-visibleLineBreak';
    span.setAttribute('content', window.config.visibleLineBreakCharacter ?? '¬');
    return span;
  }

  eq(other: LineBreakWidget) {
    return other.pos === this.pos;
  }
}
