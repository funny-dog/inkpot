// 移植自 MarkEdit-preview（https://github.com/MarkEdit-app/MarkEdit-preview）src/hiddenSyntax，上游提交 0dcde1c
// Copyright (c) 2025 MarkEdit.app，MIT License

import { WidgetType } from '@codemirror/view';

export class FootnoteDefinitionSuffix extends WidgetType {
  constructor(private readonly text: string) {
    super();
  }

  eq(other: FootnoteDefinitionSuffix) {
    return other.text === this.text;
  }

  toDOM() {
    const suffix = document.createElement('span');
    suffix.textContent = this.text;
    return suffix;
  }

  ignoreEvent() {
    return false;
  }
}
