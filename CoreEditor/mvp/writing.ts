import { commonmarkLanguage } from '@codemirror/lang-markdown';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import { formatCommands } from './format';
import { documentSearch, searchBindings } from './search';

export const writingExtensions = [
  commonmarkLanguage,
  syntaxHighlighting(HighlightStyle.define([
    { tag: tags.heading, color: '#174ea6', fontWeight: 'bold' },
    { tag: tags.strong, fontWeight: 'bold' },
    { tag: tags.emphasis, fontStyle: 'italic' },
    { tag: [tags.link, tags.url], color: '#1769aa', textDecoration: 'underline' },
    { tag: [tags.monospace, tags.processingInstruction], color: '#8a3b12' },
    { tag: [tags.list, tags.quote, tags.meta], color: '#5f6368' },
  ])),
  documentSearch,
  EditorState.phrases.of({
    'current match': '当前匹配项',
    'on line': '所在行',
    'replaced match on line $': '已替换第 $ 行的匹配项',
    'replaced $ matches': '已替换 $ 处匹配项',
  }),
  keymap.of([
    ...searchBindings,
    { key: 'Mod-b', run: formatCommands.bold },
    { key: 'Mod-i', run: formatCommands.italic },
    ...[1, 2, 3, 4, 5, 6].map(level => ({ key: `Mod-${level}`, run: formatCommands[`heading${level}`] })),
    { key: 'Mod-Shift-7', run: formatCommands.orderedList },
    { key: 'Mod-Shift-8', run: formatCommands.bulletList },
  ]),
];
