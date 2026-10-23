import { Compartment } from '@codemirror/state';
import type { Extension } from '@codemirror/state';
import { EditorView, ViewPlugin } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { highlightTag } from './gfm';

// 深色语法高亮：与 writing.ts 浅色版相同的 tag 集合，themeType 'dark' 使其只在深色主题激活时生效。
const darkHighlightStyle = HighlightStyle.define([
  { tag: tags.heading, color: '#7cb0e8', fontWeight: 'bold' },
  { tag: tags.strong, fontWeight: 'bold' },
  { tag: tags.emphasis, fontStyle: 'italic' },
  { tag: tags.strikethrough, textDecoration: 'line-through' },
  { tag: highlightTag, backgroundColor: 'rgba(255, 212, 0, 0.25)' },
  { tag: [tags.link, tags.url], color: '#7cb0e8', textDecoration: 'underline' },
  { tag: [tags.monospace, tags.processingInstruction], color: '#d99a6c' },
  { tag: [tags.list, tags.quote, tags.meta], color: '#a8adb8' },
], { themeType: 'dark' });

// 深色覆盖主题：所有选择器带 '&.cm-mvp-dark' 前缀，多出的类使特异性必然高于各模块的浅色规则，
// 与规则注入顺序无关；{ dark: true } 同时激活 CodeMirror 基础主题的 dark 作用域（光标、选区、面板等）。
const darkTheme = EditorView.theme({
  '&.cm-mvp-dark': { backgroundColor: '#1e1f22', color: '#dfe1e5' },
  '&.cm-mvp-dark .cm-scroller': { backgroundColor: '#1e1f22', color: '#dfe1e5' },
  // editor.ts 搜索面板。
  '&.cm-mvp-dark .cm-panels': { backgroundColor: '#2a2b2f', color: '#dfe1e5' },
  '&.cm-mvp-dark .cm-searchMatch': { backgroundColor: 'rgba(255, 212, 0, 0.25)' },
  '&.cm-mvp-dark .cm-searchMatch-selected': { backgroundColor: 'rgba(255, 171, 64, 0.45)' },
  // writing.ts 源码高亮配色的深色版由 darkHighlightStyle 提供，此处不重复。
  // live.ts 预览元素。
  '&.cm-mvp-dark .cm-mvp-inline-code': { backgroundColor: '#33353a' },
  '&.cm-mvp-dark .cm-mvp-link': { color: '#7cb0e8' },
  '&.cm-mvp-dark .cm-mvp-rule': { borderTop: '1px solid #3c4043' },
  '&.cm-mvp-dark .cm-mvp-list-marker': { color: '#a8adb8' },
  '&.cm-mvp-dark .cm-mvp-quote': { borderLeft: '3px solid #3c4043', color: '#a8adb8' },
  // code.ts 代码块。
  '&.cm-mvp-dark .cm-mvp-code': { backgroundColor: '#2a2b2f', color: '#c8cbd2' },
  '&.cm-mvp-dark .cm-mvp-code-language': { color: '#a8adb8' },
  // table.ts 表格。
  '&.cm-mvp-dark .cm-mvp-table th, &.cm-mvp-dark .cm-mvp-table td': { border: '1px solid #3c4043' },
  '&.cm-mvp-dark .cm-mvp-table th': { background: '#2a2b2f' },
  '&.cm-mvp-dark .cm-mvp-table-input:focus': { outline: '2px solid #7cb0e8' },
  '&.cm-mvp-dark .cm-mvp-table-hint': { color: '#a8adb8' },
  // math.ts 公式。
  '&.cm-mvp-dark .cm-mvp-math': { backgroundColor: 'rgba(124, 176, 232, 0.13)' },
  '&.cm-mvp-dark .cm-mvp-math-error': { color: '#e8736a' },
}, { dark: true });

const darkAppearance: Extension[] = [
  darkTheme,
  // 给编辑器根挂 cm-mvp-dark 类，darkTheme 的覆盖选择器与 index.html 的 body 深色都依赖它所属的外观状态。
  EditorView.editorAttributes.of(() => ({ class: 'cm-mvp-dark' })),
  syntaxHighlighting(darkHighlightStyle),
];

const appearanceCompartment = new Compartment();

/** 系统外观自检测：在页面内监听深浅色变化，无需原生脚本推送。 */
const appearanceWatch = ViewPlugin.fromClass(class {
  private readonly media: MediaQueryList | null = null;
  private readonly listener: () => void;

  constructor(view: EditorView) {
    this.listener = () => { if (this.media !== null) applyAppearance(view, this.media.matches); };
    if (typeof matchMedia === 'function') {
      this.media = matchMedia('(prefers-color-scheme: dark)');
      this.media.addEventListener('change', this.listener);
      // 原生传入的初始值与页面感知不一致时以页面为准。
      if (view.dom.matches('.cm-mvp-dark') !== this.media.matches) applyAppearance(view, this.media.matches);
    }
  }

  destroy() { this.media?.removeEventListener('change', this.listener); }
});

/** 打开文档时的初始外观扩展：原生传入初始值，页面内自检测后续变化。 */
export function appearanceExtensionsFor(dark: boolean): Extension[] {
  return [appearanceCompartment.of(dark ? darkAppearance : []), appearanceWatch];
}

/** 跟随系统的深浅色外观切换：重配置编辑器外观，并同步页面根类供 body 背景切换。 */
export function applyAppearance(view: EditorView, dark: boolean): void {
  view.dispatch({ effects: appearanceCompartment.reconfigure(dark ? darkAppearance : []) });
  document.documentElement.classList.toggle('inkpot-dark', dark);
}
