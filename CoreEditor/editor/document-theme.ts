import { Facet, Prec } from '@codemirror/state';
import type { Extension } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { themePalettes } from './theme-palettes';
import { themeLayout } from './theme-layout';

/** 内置主题适配上游配色和排版，保留编辑行为；来源见 themes/NOTICES.md。 */
export const documentTheme = Facet.define<string, string>({ combine: values => values[0] ?? 'default' });

export function validTheme(name: string): string {
  return Object.hasOwn(themePalettes, name) ? name : 'default';
}

export function documentThemeExtensions(name: string, dark: boolean): Extension[] {
  const palette = themePalettes[name]?.[dark ? 'dark' : 'light'];
  if (palette === undefined) return [];
  // 额外的 cm-editor 类让配色优先于现有模块和默认深色规则，不改变它们的布局。
  const prefix = '&.cm-editor.cm-inkpot-themed';
  const styles = EditorView.theme({
    [prefix]: { backgroundColor: palette.background, color: palette.text },
    [`${prefix} .cm-scroller`]: { backgroundColor: palette.background, color: palette.text },
    [`${prefix} .cm-content`]: { caretColor: palette.accent },
    [`${prefix} .cm-cursor`]: { borderLeftColor: palette.accent },
    [`${prefix}.cm-focused .cm-selectionBackground, ${prefix} .cm-selectionBackground, ${prefix} ::selection`]: { backgroundColor: palette.selection },
    [`${prefix} .cm-inkpot-heading1, ${prefix} .cm-inkpot-heading2, ${prefix} .cm-inkpot-heading3, ${prefix} .cm-inkpot-heading4, ${prefix} .cm-inkpot-heading5, ${prefix} .cm-inkpot-heading6`]: { color: palette.heading },
    [`${prefix} .cm-inkpot-link`]: { color: palette.accent },
    [`${prefix} .cm-inkpot-inline-code`]: { backgroundColor: palette.code, color: palette.codeText },
    [`${prefix} .cm-inkpot-quote`]: { borderLeftColor: palette.accent, color: palette.muted, backgroundColor: palette.quote },
    [`${prefix} .cm-inkpot-rule`]: { borderTopColor: palette.border },
    [`${prefix} .cm-inkpot-list-marker, ${prefix} .cm-placeholder, ${prefix} .cm-inkpot-code-language, ${prefix} .cm-inkpot-table-hint`]: { color: palette.muted },
    [`${prefix} .cm-inkpot-code`]: { backgroundColor: palette.code, color: palette.codeText },
    [`${prefix} .cm-inkpot-token-keyword`]: { color: palette.keyword },
    [`${prefix} .cm-inkpot-token-string`]: { color: palette.string },
    [`${prefix} .cm-inkpot-token-comment`]: { color: palette.comment },
    [`${prefix} .cm-inkpot-token-number, ${prefix} .cm-inkpot-token-property`]: { color: palette.number },
    [`${prefix} .cm-inkpot-token-type`]: { color: palette.type },
    [`${prefix} .cm-inkpot-token-function, ${prefix} .cm-inkpot-token-link`]: { color: palette.function },
    [`${prefix} .cm-inkpot-token-tag, ${prefix} .cm-inkpot-token-meta, ${prefix} .cm-inkpot-token-builtin`]: { color: palette.accent },
    [`${prefix} .cm-inkpot-table th, ${prefix} .cm-inkpot-table td`]: { borderColor: palette.border },
    [`${prefix} .cm-inkpot-table th`]: { backgroundColor: palette.surface },
    [`${prefix} .cm-inkpot-table-input:focus`]: { outlineColor: palette.accent },
    [`${prefix} .cm-inkpot-math`]: { backgroundColor: palette.quote },
    [`${prefix} .cm-panels, ${prefix} .cm-tooltip`]: { backgroundColor: palette.surface, color: palette.text },
    [`${prefix} .cm-panels.cm-panels-top`]: { borderBottomColor: palette.border },
    [`${prefix} .cm-inkpot-search-field`]: { backgroundColor: palette.background, borderColor: palette.border, color: palette.muted },
    [`${prefix} .cm-inkpot-search-field:focus-within`]: { borderColor: palette.accent, boxShadow: `0 0 0 2px ${palette.selection}` },
    [`${prefix} .cm-inkpot-search-field input, ${prefix} .cm-inkpot-search-nav button`]: { color: palette.text },
    [`${prefix} .cm-inkpot-search-options label, ${prefix} .cm-inkpot-search [role=status]`]: { color: palette.muted },
    [`${prefix} .cm-inkpot-search-options label:has(input:checked)`]: { backgroundColor: palette.selection, color: palette.text },
    [`${prefix} .cm-inkpot-search-divider`]: { backgroundColor: palette.border },
    [`${prefix} .cm-inkpot-search-nav, ${prefix} .cm-inkpot-search-action`]: { backgroundColor: palette.background, borderColor: palette.border, color: palette.text },
    [`${prefix} .cm-inkpot-search-nav button + button`]: { borderLeftColor: palette.border },
  });
  const highlighting = HighlightStyle.define([
    { tag: tags.heading, color: palette.heading, fontWeight: 'bold' },
    { tag: [tags.link, tags.url], color: palette.accent, textDecoration: 'underline' },
    { tag: [tags.monospace, tags.processingInstruction], color: palette.codeText },
    { tag: [tags.list, tags.quote, tags.meta], color: palette.muted },
  ]);
  return [Prec.highest(themeLayout(name, palette, dark)), Prec.highest(styles), Prec.highest(syntaxHighlighting(highlighting)), EditorView.editorAttributes.of({ class: 'cm-inkpot-themed', 'data-theme': name })];
}
