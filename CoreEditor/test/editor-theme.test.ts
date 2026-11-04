import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { applyAppearance, appearanceExtensionsFor } from '../editor/theme';
import { useKatexForTests } from '../editor/math';
import { documentTheme } from '../editor/document-theme';
import { themePalettes } from '../editor/theme-palettes';
import { applyFonts } from '../editor/fonts';

// 公式 widget 渲染是异步的，测试注入假 KaTeX 避免从应用包加载。
useKatexForTests({
  render(_tex, element) {
    element.textContent = '公式';
    element.classList.add('fake-katex');
  },
});

const views: EditorView[] = [];
afterEach(() => {
  for (const view of views.splice(0)) view.destroy();
  document.documentElement.classList.remove('inkpot-dark');
  document.documentElement.style.removeProperty('--inkpot-theme-background');
  document.documentElement.style.removeProperty('--inkpot-theme-text');
});
function editor(text: string) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, ...appearanceExtensionsFor(false), history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}
async function flushed() {
  await new Promise(resolve => setTimeout(resolve, 0));
}

const original = '# 标题\r\n\r\n正文 `code` 与 $x^2$ 公式\r\n\r\n```js\r\nconst a = 1;\r\n```\r\n\r\n| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\n> 引用';

describe('Inkpot 外观', () => {
  test('主题字体、行距和标题排版随选择变化，自定义字体优先且源码模式保留等宽字体', () => {
    const original = '# 标题\r\n\r\n## 小标题\r\n\r\n正文';
    const { view, read } = editor(original);
    applyFonts(view, { bodyFamily: '', bodySize: 18, codeFamily: '', codeSize: 16 });
    applyAppearance(view, false, 'lapis');
    expect(getComputedStyle(view.dom).getPropertyValue('--inkpot-theme-body-font')).toContain('Songti SC');
    const heading = view.dom.querySelector('.cm-inkpot-heading1');
    const subheading = view.dom.querySelector('.cm-inkpot-heading2');
    if (heading === null || subheading === null) throw new Error('缺少标题');
    expect(getComputedStyle(heading).textAlign).toBe('center');
    expect(getComputedStyle(subheading).borderRadius).toBe('4px');
    applyAppearance(view, false, 'phycat');
    expect(getComputedStyle(view.dom).getPropertyValue('--inkpot-theme-body-font')).toContain('Kaiti SC');
    expect(getComputedStyle(view.scrollDOM).lineHeight).toBe('2.25');
    applyFonts(view, { bodyFamily: 'Helvetica', bodySize: 18, codeFamily: 'Menlo', codeSize: 16 });
    applyAppearance(view, false, 'ursine');
    expect(view.dom.style.getPropertyValue('--inkpot-body-font')).toContain('Helvetica');
    expect(view.dom.style.getPropertyValue('--inkpot-body-size')).toBe('18px');
    toggleSourceMode(view);
    expect(view.dom.matches('.cm-inkpot-source')).toBe(true);
    expect(getComputedStyle(view.scrollDOM).lineHeight).not.toBe('1.6');
    toggleSourceMode(view);
    applyFonts(view, { bodyFamily: '', bodySize: 18, codeFamily: '', codeSize: 16 });
    expect(view.dom.style.getPropertyValue('--inkpot-body-font')).toBe('');
    applyAppearance(view, false, 'default');
    expect(getComputedStyle(view.dom).getPropertyValue('--inkpot-theme-body-font')).toBe('');
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('全部内置配色的正文、代码和次要文字保持可读对比度', () => {
    function luminance(color: string): number {
      const channels = [1, 3, 5].map(offset => parseInt(color.slice(offset, offset + 2), 16) / 255)
        .map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
      return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
    }
    for (const theme of Object.values(themePalettes)) {
      if (theme === undefined) throw new Error('缺少主题配色');
      for (const palette of [theme.light, theme.dark]) {
        for (const [foreground, background, minimum] of [['text', 'background', 4.5], ['codeText', 'code', 4.5], ['muted', 'background', 3]] as const) {
          const light = luminance(palette[foreground]), dark = luminance(palette[background]);
          expect((Math.max(light, dark) + .05) / (Math.min(light, dark) + .05)).toBeGreaterThanOrEqual(minimum);
        }
      }
    }
  });

  test.each(['lapis', 'ursine', 'notion', 'pie', 'drake', 'phycat', 'dracula'])('内置 %s 配色可切换明暗并保留文档、选区和撤销历史', name => {
    const { view, read } = editor(original);
    view.dispatch({ selection: { anchor: 4 } });
    for (const dark of [false, true]) {
      applyAppearance(view, dark, name);
      const effectiveDark = dark || name === 'dracula';
      const palette = themePalettes[name]?.[effectiveDark ? 'dark' : 'light'];
      if (palette === undefined) throw new Error(`缺少主题配色：${name}`);
      const swatch = document.createElement('span');
      swatch.style.backgroundColor = palette.background;
      expect(getComputedStyle(view.dom).backgroundColor).toBe(swatch.style.backgroundColor);
      expect(view.state.facet(EditorView.darkTheme)).toBe(effectiveDark);
      const language = view.dom.querySelector('select.cm-inkpot-code-language');
      if (language === null) throw new Error('缺少代码语言选择器');
      expect(getComputedStyle(language).colorScheme).toBe(effectiveDark ? 'dark' : 'light');
      expect(view.dom.dataset.theme).toBe(name);
      expect(document.documentElement.style.getPropertyValue('--inkpot-theme-background')).toBe(palette.background);
      expect(view.state.selection.main.head).toBe(4);
      expect(read()).toBe(original);
      expect(undoDepth(view.state)).toBe(0);
    }
    applyAppearance(view, false, 'default');
    expect(view.dom.dataset.theme).toBeUndefined();
    expect(document.documentElement.style.getPropertyValue('--inkpot-theme-background')).toBe('');
    expect(view.state.facet(EditorView.darkTheme)).toBe(false);
  });

  test('明暗变化保留主题，未知标识安全回退到默认主题', () => {
    const { view } = editor(original);
    applyAppearance(view, false, 'lapis');
    applyAppearance(view, true);
    expect(view.state.facet(documentTheme)).toBe('lapis');
    expect(view.dom.dataset.theme).toBe('lapis');
    for (const name of ['missing', '__proto__', 'constructor']) {
      applyAppearance(view, false, name);
      expect(view.state.facet(documentTheme)).toBe('default');
      expect(view.dom.dataset.theme).toBeUndefined();
    }
  });

  test('初始为浅色：编辑器无 cm-inkpot-dark，页面根无 inkpot-dark，dark 主题未激活', () => {
    const { view } = editor(original);
    expect(view.dom.classList.contains('cm-inkpot-dark')).toBe(false);
    expect(view.dom.classList.contains('cm-inkpot-live')).toBe(true);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(false);
    expect(view.state.facet(EditorView.darkTheme)).toBe(false);
  });

  test('applyAppearance(true) 给编辑器根挂 cm-inkpot-dark、页面根挂 inkpot-dark，dark 作用域激活', () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    expect(view.dom.classList.contains('cm-inkpot-dark')).toBe(true);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(true);
    expect(view.state.facet(EditorView.darkTheme)).toBe(true);
    // 与预览模式的类共存，不被外观切换覆盖。
    expect(view.dom.classList.contains('cm-inkpot-live')).toBe(true);
  });

  test('切回浅色后编辑器与页面根的深色类都移除，dark 作用域关闭', () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    applyAppearance(view, false);
    expect(view.dom.classList.contains('cm-inkpot-dark')).toBe(false);
    expect(document.documentElement.classList.contains('inkpot-dark')).toBe(false);
    expect(view.state.facet(EditorView.darkTheme)).toBe(false);
  });

  test('外观切换不修改源文档字节，也不产生可撤销的历史', () => {
    const { view, read } = editor(original);
    applyAppearance(view, true);
    applyAppearance(view, false);
    applyAppearance(view, true);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('深色下表格、代码块、行内代码、行内公式与引用照常渲染', async () => {
    const { view } = editor(original);
    applyAppearance(view, true);
    await flushed();
    expect(view.dom.querySelector('.cm-inkpot-table table')).not.toBeNull();
    expect(view.dom.querySelectorAll('.cm-inkpot-table th')).toHaveLength(2);
    expect(view.dom.querySelector('.cm-inkpot-code')).not.toBeNull();
    expect(view.dom.querySelector<HTMLSelectElement>('.cm-inkpot-code-language')?.value).toBe('javascript');
    expect(view.dom.querySelector('.cm-inkpot-inline-code')).not.toBeNull();
    expect(view.dom.querySelector('.cm-inkpot-math.fake-katex')).not.toBeNull();
    expect(view.dom.querySelector('.cm-inkpot-quote')).not.toBeNull();
  });

  test('浅色切深色再切回，已渲染的 widget 仍在且文档可继续编辑撤销', async () => {
    const { view, read } = editor(original);
    await flushed();
    applyAppearance(view, true);
    applyAppearance(view, false);
    expect(view.dom.querySelector('.cm-inkpot-table table')).not.toBeNull();
    expect(view.dom.querySelector('.cm-inkpot-math.fake-katex')).not.toBeNull();
    view.dispatch({ changes: { from: 0, insert: '新增' } });
    expect(read().startsWith('新增# 标题')).toBe(true);
    expect(undoDepth(view.state)).toBe(1);
  });
});
