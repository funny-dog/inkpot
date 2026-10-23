import { commonmarkLanguage } from '@codemirror/lang-markdown';
import { HighlightStyle, Language, syntaxHighlighting } from '@codemirror/language';
import { MarkdownParser, Strikethrough, Table, TaskList } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { formatCommands } from './format';
import { documentSearch, searchBindings } from './search';
import { typingBindings } from './typing';
import { footnoteExtension, highlightExtension, highlightTag } from './gfm';
import { inlineMathExtension, markdownMathExtension } from './math';

export const writingExtensions = [
  new Language(commonmarkLanguage.data, (commonmarkLanguage.parser as MarkdownParser).configure([Table, markdownMathExtension, inlineMathExtension, Strikethrough, TaskList, highlightExtension, footnoteExtension]), [], 'markdown'),
  syntaxHighlighting(HighlightStyle.define([
    { tag: tags.heading, color: '#174ea6', fontWeight: 'bold' },
    { tag: tags.strong, fontWeight: 'bold' },
    { tag: tags.emphasis, fontStyle: 'italic' },
    { tag: tags.strikethrough, textDecoration: 'line-through' },
    { tag: highlightTag, backgroundColor: 'rgba(255, 212, 0, 0.4)' },
    { tag: [tags.link, tags.url], color: '#1769aa', textDecoration: 'underline' },
    { tag: [tags.monospace, tags.processingInstruction], color: '#8a3b12' },
    { tag: [tags.list, tags.quote, tags.meta], color: '#5f6368' },
  ], { themeType: 'light' })),
  documentSearch,
  EditorState.phrases.of({
    'current match': '当前匹配项',
    'on line': '所在行',
    'replaced match on line $': '已替换第 $ 行的匹配项',
    'replaced $ matches': '已替换 $ 处匹配项',
  }),
  keymap.of([
    ...searchBindings,
    ...typingBindings,
    { key: 'Mod-b', run: formatCommands.bold },
    { key: 'Mod-i', run: formatCommands.italic },
    ...[1, 2, 3, 4, 5, 6].map(level => ({ key: `Mod-${level}`, run: formatCommands[`heading${level}`] })),
    { key: 'Mod-Shift-7', run: formatCommands.orderedList },
    { key: 'Mod-Shift-8', run: formatCommands.bulletList },
  ]),
];
