import { afterEach, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { applyFonts } from '../editor/fonts';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

test('正文与代码字体独立更新，切换模式保留字体、原文和撤销历史', () => {
  const original = '正文\r\n\r\n```js\ncode\n```';
  const source = sourceDocument(original);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()],
  }) });
  views.push(view);
  applyFonts(view, { bodyFamily: 'PingFang SC', bodySize: 20, codeFamily: 'SF Mono', codeSize: 17 });
  expect(view.dom.style.getPropertyValue('--inkpot-body-font')).toBe('"PingFang SC", system-ui, sans-serif');
  expect(view.dom.style.getPropertyValue('--inkpot-code-font')).toBe('"SF Mono", Menlo, monospace');
  expect(view.dom.style.getPropertyValue('--inkpot-body-size')).toBe('20px');
  expect(view.dom.style.getPropertyValue('--inkpot-code-size')).toBe('17px');
  toggleSourceMode(view);
  toggleSourceMode(view);
  expect(view.dom.style.getPropertyValue('--inkpot-body-size')).toBe('20px');
  expect(source.read(view.state)).toBe(original);
  expect(undoDepth(view.state)).toBe(0);
});

test('空字体名使用系统回退，无效字号回退到默认值', () => {
  const view = new EditorView({ parent: document.body });
  views.push(view);
  applyFonts(view, { bodyFamily: '', bodySize: NaN, codeFamily: '', codeSize: 1000 });
  expect(view.dom.style.getPropertyValue('--inkpot-body-font')).toBe('system-ui, sans-serif');
  expect(view.dom.style.getPropertyValue('--inkpot-code-font')).toBe('Menlo, monospace');
  expect(view.dom.style.getPropertyValue('--inkpot-body-size')).toBe('15px');
  expect(view.dom.style.getPropertyValue('--inkpot-code-size')).toBe('15px');
});
