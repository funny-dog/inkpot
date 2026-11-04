import { EditorView } from '@codemirror/view';
import type { ThemePalette } from './theme-palettes';

/** 沿用原主题的字体风格与排版比例；未打包的字体回退到系统现有字体，来源见 themes/NOTICES.md。 */
const typography: Readonly<Partial<Record<string, {
  body: string; heading: string; code: string; lineHeight: string; letterSpacing: string; width: string; headings: number[];
}>>> = {
  lapis: { body: 'Cantarell, "Songti SC", "Noto Serif CJK SC", serif', heading: '"Songti SC", "Noto Serif CJK SC", serif', code: '"JetBrains Mono", Menlo, monospace', lineHeight: '1.8', letterSpacing: '0', width: '950px', headings: [2, 1.5, 1.4, 1.2, 1.1, 1.1] },
  ursine: { body: '"Avenir Next", "PingFang SC", sans-serif', heading: 'Georgia, "Songti SC", serif', code: '"Fira Mono", Menlo, monospace', lineHeight: '1.6', letterSpacing: '0', width: '796px', headings: [1.8, 1.4, 1.2, 1.1, 1, 1] },
  notion: { body: 'system-ui, "PingFang SC", sans-serif', heading: 'system-ui, "PingFang SC", sans-serif', code: '"SF Mono", Menlo, monospace', lineHeight: '1.6', letterSpacing: '0', width: '956px', headings: [2.2, 1.75, 1.4, 1.2, 1, 1] },
  pie: { body: '"Source Sans Pro", "Helvetica Neue", "PingFang SC", sans-serif', heading: '"Source Sans Pro", "Helvetica Neue", "PingFang SC", sans-serif', code: '"Fira Code", Monaco, monospace', lineHeight: '1.8', letterSpacing: '0', width: '956px', headings: [2, 1.6, 1.35, 1.2, 1, 1] },
  drake: { body: '"Helvetica Neue", "PingFang SC", sans-serif', heading: '"Helvetica Neue", "PingFang SC", sans-serif', code: '"JetBrains Mono", Menlo, monospace', lineHeight: '1.8', letterSpacing: '0', width: '956px', headings: [2, 1.8, 1.4, 1.2, 1, 1] },
  phycat: { body: '"LXGW WenKai", "Kaiti SC", STKaiti, KaiTi, serif', heading: 'Optima, "Kaiti SC", STKaiti, KaiTi, serif', code: '"Cascadia Code", Menlo, monospace', lineHeight: '2.25', letterSpacing: '1.1px', width: '1046px', headings: [1.8, 1.4, 1.3, 1.15, 1.1, 1.1] },
  dracula: { body: '"Helvetica Neue", "PingFang SC", sans-serif', heading: '"Lucida Grande", "PingFang SC", sans-serif', code: '"Fira Code", Monaco, monospace', lineHeight: '1.625', letterSpacing: '0', width: '1010px', headings: [2.5, 1.63, 1.17, 1.12, .97, .93] },
};

export function themeLayout(name: string, palette: ThemePalette, dark: boolean) {
  const type = typography[name];
  if (type === undefined) return [];
  const root = '&.cm-editor.cm-inkpot-themed';
  const live = root + '.cm-inkpot-live';
  const styles: Parameters<typeof EditorView.theme>[0] = {
    [root]: { '--inkpot-theme-body-font': type.body, '--inkpot-theme-code-font': type.code },
    [`${live} .cm-scroller`]: { lineHeight: type.lineHeight, letterSpacing: type.letterSpacing },
    [`${live} .cm-content`]: { maxWidth: type.width, boxSizing: 'border-box' },
    [`${live} .cm-inkpot-inline-code, ${live} .cm-inkpot-code`]: { letterSpacing: '0' },
    [`${live} .cm-inkpot-code:not(.cm-inkpot-code-header):not(.cm-inkpot-code-footer)`]: { lineHeight: '1.6' },
  };
  const accents: Parameters<typeof EditorView.theme>[0] = {};
  for (const [index, size] of type.headings.entries()) {
    styles[`${live} .cm-inkpot-heading${index + 1}`] = {
      fontFamily: `var(--inkpot-body-font, ${type.heading})`, fontSize: `${size}em`, lineHeight: '1.4',
      paddingTop: index < 2 ? '.8em' : '.6em', paddingBottom: '.25em', letterSpacing: '0',
    };
  }
  // 用 padding 代替原主题的标题 margin，让 CodeMirror 能正确测量行高和光标位置。
  switch (name) {
    case 'lapis':
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { textAlign: 'center', paddingBottom: '1.15em' },
        [`${live} .cm-inkpot-heading2`]: { width: 'fit-content', maxWidth: '100%', padding: '4px 12px', borderRadius: '4px', backgroundColor: palette.accent, color: dark ? palette.background : '#ffffff' },
        [`${live} .cm-inkpot-heading2 span`]: { color: 'inherit' },
        [`${live} .cm-inkpot-quote`]: { padding: '12px 20px', borderRadius: '4px', fontSize: '.95em' },
      });
      break;
    case 'ursine':
      Object.assign(accents, {
        [`${live} .cm-inkpot-quote`]: { fontFamily: `var(--inkpot-body-font, ${type.heading})`, fontSize: '1.1em', padding: '6px 20px', borderLeftWidth: '2px', backgroundColor: 'transparent' },
        [`${live} .cm-inkpot-heading1`]: { paddingTop: '.55em', paddingBottom: '.55em' },
        [`${live} .cm-inkpot-table th`]: { backgroundColor: palette.border },
      });
      break;
    case 'notion':
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { fontWeight: '700', letterSpacing: '-.025em' },
        [`${live} .cm-inkpot-heading2`]: { letterSpacing: '-.02em' },
        [`${live} .cm-inkpot-quote`]: { borderLeftColor: palette.text, padding: '3px 16px', color: palette.text, backgroundColor: 'transparent' },
        [`${live} .cm-inkpot-table th`]: { backgroundColor: palette.background, fontWeight: '600' },
      });
      break;
    case 'pie':
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { borderBottom: `2px solid ${palette.accent}`, paddingBottom: '.4em' },
        [`${live} .cm-inkpot-heading2`]: { borderLeft: `6px solid ${palette.accent}`, paddingLeft: '12px', paddingTop: '.15em', paddingBottom: '.15em' },
        [`${live} .cm-inkpot-quote`]: { borderLeftWidth: '4px', borderRadius: '4px', padding: '10px 20px' },
        [`${live} .cm-inkpot-link`]: { textDecorationStyle: 'dotted' },
      });
      break;
    case 'drake':
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { textAlign: 'center', paddingBottom: '.6em' },
        [`${live} .cm-inkpot-heading2`]: { borderBottom: `1px solid ${palette.heading}`, paddingBottom: '.5em' },
        [`${live} .cm-inkpot-quote`]: { borderLeftWidth: '4px', borderRadius: '6px', padding: '12px 18px', color: palette.text },
        [`${live} .cm-inkpot-table tr:nth-child(even) td`]: { backgroundColor: palette.surface },
      });
      break;
    case 'phycat': {
      const background = dark ? 'linear-gradient(90deg, #1d3b53, #1f2233)' : 'linear-gradient(90deg, #008145, #009a52)';
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { textAlign: 'center', paddingBottom: '.6em', borderBottom: `3px solid ${palette.accent}` },
        [`${live} .cm-inkpot-heading2`]: { width: 'fit-content', maxWidth: '100%', padding: '5px 12px', borderRadius: '8px', background, color: dark ? palette.text : '#ffffff' },
        [`${live} .cm-inkpot-heading2 span`]: { color: 'inherit' },
        [`${live} .cm-inkpot-quote`]: { padding: '12px 20px', borderRadius: '10px', borderLeftWidth: '4px', boxShadow: `inset 0 0 0 1px ${palette.border}` },
        [`${live} .cm-inkpot-table-preview, ${live} .cm-inkpot-table-input`]: { padding: '10px 14px' },
      });
      break;
    }
    case 'dracula':
      Object.assign(accents, {
        [`${live} .cm-inkpot-heading1`]: { fontWeight: '400', letterSpacing: '-1.5px' },
        [`${live} .cm-inkpot-heading2`]: { letterSpacing: '-1px' },
        [`${live} .cm-inkpot-quote`]: { borderLeft: `4px solid ${palette.heading}`, backgroundColor: 'transparent', padding: '8px 18px', fontStyle: 'italic' },
        [`${live} .cm-inkpot-table th`]: { backgroundColor: palette.surface },
      });
      break;
  }
  for (const [selector, rules] of Object.entries(accents)) styles[selector] = { ...styles[selector], ...rules };
  return EditorView.theme(styles);
}
