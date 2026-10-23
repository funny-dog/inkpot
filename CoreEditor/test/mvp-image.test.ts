import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing, toggleSourceMode } from '../mvp/live';
import { refreshImages, setImageDocument } from '../mvp/image';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });
function editor(text: string) {
  setImageDocument(7);
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

describe('MVP 本地图片', () => {
  test('本地路径经自定义协议读取，保留 Unicode、转义与原文行尾', () => {
    const original = '前\r\n\r\n![示意](<assets/中文 图.png>)\r\n尾\n';
    const { view, read } = editor(original);
    const image = view.contentDOM.querySelector('.cm-mvp-image img');
    expect(image?.getAttribute('src')).toContain('kernmark-image://local/assets%2F');
    expect(image?.getAttribute('src')).toContain('document=7&revision=0');
    expect(image?.alt).toBe('示意');
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('双击展开图片源文，移开选区后恢复预览，切换模式不改文档', () => {
    const original = '前 ![图](assets/a.png) 后';
    const { view, read } = editor(original);
    const preview = view.contentDOM.querySelector('.cm-mvp-image');
    if (preview === null) throw new Error('缺少图片预览');
    preview.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true }));
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('![图](assets/a.png)');
    expect(view.contentDOM.querySelector('.cm-mvp-image img')).toBeNull();
    view.dispatch({ selection: { anchor: 0 } });
    expect(view.contentDOM.querySelector('.cm-mvp-image img')).not.toBeNull();
    toggleSourceMode(view);
    expect(view.contentDOM.querySelector('.cm-mvp-image img')).toBeNull();
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('支持引用式图片，不把远程、脚本、data URI 或协议相对地址交给图片加载器', () => {
    const { view } = editor('前 ![a][id] ![shortcut]\n\n[id]: assets/a.png\n[shortcut]: ./b.png\n\n![r](https://example.com/a.png) ![s](javascript:evil) ![d](data:image/png,test) ![p](//example.com/a.png)');
    const images = [...view.contentDOM.querySelectorAll('.cm-mvp-image img')];
    expect(images).toHaveLength(2);
    expect(images.every(img => img.getAttribute('src')?.startsWith('kernmark-image:') === true)).toBe(true);
  });

  test('图片失效时提供可编辑的提示，版本变化重新解析当前位置的图片', () => {
    const { view } = editor('前 ![缺失](missing.png)');
    const image = view.contentDOM.querySelector('.cm-mvp-image img');
    image?.dispatchEvent(new Event('error'));
    expect(image?.alt).toContain('图片无法读取');
    view.dispatch({ effects: refreshImages.of(null) });
    expect(view.contentDOM.querySelector('.cm-mvp-image img')?.getAttribute('src')).toContain('revision=1');
  });

  test('代码、原始 HTML 和行内代码中的图片标记不渲染', () => {
    const { view } = editor('`![x](a.png)`\n\n```\n![y](b.png)\n```\n\n<div>\n![z](c.png)\n</div>');
    expect(view.contentDOM.querySelector('.cm-mvp-image img')).toBeNull();
  });
});
