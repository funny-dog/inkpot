import { t } from './localization';
import { commonmarkLanguage } from '@codemirror/lang-markdown';
import { HighlightStyle, Language, syntaxHighlighting } from '@codemirror/language';
import { MarkdownParser, Strikethrough, Table, TaskList } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { formatCommands } from './format';
import { documentSearch, searchBindings } from './search';
import { autoPairs, pairingCompartment, typingBindings } from './typing';
import { footnoteExtension, highlightExtension, highlightTag } from './gfm';
import { inlineMathExtension } from './math';
import { markdownMathWith } from './math-parser';
import { codeHighlighting, codeHighlightTheme, codeNest } from './code-languages';

export const writingExtensions = [
  new Language(commonmarkLanguage.data, (commonmarkLanguage.parser as MarkdownParser).configure([Table, markdownMathWith(codeNest), inlineMathExtension, Strikethrough, TaskList, highlightExtension, footnoteExtension]), [], 'markdown'),
  codeHighlighting,
  codeHighlightTheme,
  syntaxHighlighting(HighlightStyle.define([
    { tag: tags.heading, fontWeight: 'bold' },
    { tag: tags.strong, fontWeight: 'bold' },
    { tag: tags.emphasis, fontStyle: 'italic' },
    { tag: tags.strikethrough, textDecoration: 'line-through' },
    { tag: highlightTag, backgroundColor: 'rgba(255, 212, 0, 0.4)' },
    { tag: [tags.link, tags.url], color: '#2b5a8c', textDecoration: 'underline' },
    { tag: [tags.monospace, tags.processingInstruction], color: '#8a3b12' },
    { tag: [tags.list, tags.quote, tags.meta], color: '#6e6e73' },
  ], { themeType: 'light' })),
  documentSearch,
  autoPairs,
  pairingCompartment.of([]),
  EditorState.phrases.compute([], () => ({
    'current match': t('当前匹配项'),
    'on line': t('所在行'),
    'replaced match on line $': t('已替换第 $ 行的匹配项'),
    'replaced $ matches': t('已替换 $ 处匹配项'),
  })),
  keymap.of([
    ...searchBindings,
    ...typingBindings,
    { key: 'Mod-b', run: formatCommands.bold },
    { key: 'Mod-i', run: formatCommands.italic },
    { key: 'Mod-Shift-x', run: formatCommands.strikethrough },
    { key: 'Mod-e', run: formatCommands.inlineCode },
    { key: 'Mod-k', run: formatCommands.link },
    { key: 'Mod-Shift-.', run: formatCommands.blockquote },
    { key: 'Mod-Shift-9', run: formatCommands.taskList },
    { key: 'Mod-Shift-c', run: formatCommands.codeBlock },
    { key: 'Mod-Shift-h', run: formatCommands.horizontalRule },
    ...[1, 2, 3, 4, 5, 6].map(level => ({ key: `Mod-${level}`, run: formatCommands[`heading${level}`] })),
    { key: 'Mod-Shift-7', run: formatCommands.orderedList },
    { key: 'Mod-Shift-8', run: formatCommands.bulletList },
  ]),
];
