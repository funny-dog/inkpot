import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { spellingExclusions } from '../editor/spelling';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, spellingExclusions],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

// 收集被标记为不检查拼写的文本。
function excludedText(view: EditorView) {
  return [...view.contentDOM.querySelectorAll('[spellcheck="false"]')].map(element => element.textContent);
}

describe('Inkpot 拼写检查范围', () => {
  const text = '正文 teh word `inlin cod` 与 [链接](https://exmple.com/pth)\n\n```js\nconst vlaue = 1;\n```\n\n<span>htm</span>';

  test('代码、链接地址与 HTML 不检查拼写，正文保持检查，原文不变', () => {
    const { view, read } = editor(text);
    toggleSourceMode(view);
    const excluded = excludedText(view).join('|');
    expect(excluded).toContain('inlin cod');
    expect(excluded).toContain('https://exmple.com/pth');
    expect(excluded).toContain('const vlaue = 1;');
    expect(excluded).toContain('<span>');
    expect(excluded).not.toContain('teh word');
    expect(read()).toBe(text);
  });

  test('编辑后更新标记范围，撤销不受影响', () => {
    const { view, read } = editor('plain text');
    expect(excludedText(view)).toEqual([]);
    view.dispatch({ changes: { from: 0, insert: '`code` ' } });
    expect(excludedText(view).join('|')).toContain('code');
    expect(read()).toBe('`code` plain text');
  });
});
