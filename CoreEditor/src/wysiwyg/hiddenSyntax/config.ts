// 移植自 MarkEdit-preview（https://github.com/MarkEdit-app/MarkEdit-preview）src/hiddenSyntax，上游提交 0dcde1c
// Copyright (c) 2025 MarkEdit.app，MIT License

import { Facet } from '@codemirror/state';
import { inlineRendering, type InlineRenderingType } from '../settings';

export const inlineRenderingConfig = Facet.define<readonly InlineRenderingType[], readonly InlineRenderingType[]>({
  combine: values => values[values.length - 1] ?? inlineRendering,
});
