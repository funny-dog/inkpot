import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView, keymap } from '@codemirror/view';
import { defaultKeymap, history, undoDepth } from '@codemirror/commands';
import { syntaxParserRunning } from '@codemirror/language';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing, toggleSourceMode } from '../editor/live';
import { readFileSync } from 'fs';
import { codeLanguageFor, languageFiles, loadDocumentLanguages } from '../editor/code-languages';
import { typingBindings } from '../editor/typing';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string, position = 0) {
  const source = sourceDocument(text);
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: source.doc, selection: EditorSelection.cursor(position),
    extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history(), keymap.of([...typingBindings, ...defaultKeymap])],
  }) });
  views.push(view);
  return { view, read: () => source.read(view.state) };
}

// 语言文件异步加载后 CodeMirror 才重新解析，等待解析与着色完成。
async function highlighted(view: EditorView) {
  await loadDocumentLanguages();
  for (let attempt = 0; attempt < 50; attempt++) {
    await new Promise(resolve => setTimeout(resolve, 20));
    if (!syntaxParserRunning(view) && view.contentDOM.querySelector('[class*="cm-inkpot-token-"]') !== null) return;
  }
}

const tokens = (view: EditorView, kind: string) => [...view.contentDOM.querySelectorAll(`.cm-inkpot-token-${kind}`)].map(element => element.textContent);

describe('Inkpot 代码块语法着色', () => {
  test.each([
    ['js', 'JavaScript'], ['TypeScript', 'TypeScript'], ['tsx', 'TypeScript'], ['py title="a.py"', 'Python'], ['python{.numberLines}', 'Python'],
    ['c++', 'C++'], ['C#', 'C#'], ['sh', 'Shell'], ['zsh', 'Shell'], ['yml', 'YAML'], ['golang', 'Go'], ['rs', 'Rust'],
    ['swift', 'Swift'], ['kotlin', 'Kotlin'], ['json', 'JSON'], ['html', 'HTML'], ['css', 'CSS'], ['sql', 'SQL'],
    ['md', 'Markdown'], ['diff', 'Diff'], ['dockerfile', 'Dockerfile'], ['toml', 'TOML'], ['rb', 'Ruby'], ['lua', 'Lua'],
  ])('围栏信息 %s 识别为 %s', (info, name) => {
    expect(codeLanguageFor(info)?.name).toBe(name);
  });

  test('构建脚本打包的语言文件与语言表一致', () => {
    const script = readFileSync(`${__dirname}/../scripts/build-render-assets.mjs`, 'utf8');
    const listed = JSON.parse((/const languages = (\[[^\]]*\])/.exec(script)?.[1] ?? '[]').replace(/'/g, '"')) as string[];
    expect([...listed].sort()).toEqual([...languageFiles].sort());
  });

  test.each(['', 'unknown', 'mermaid', 'math', '  '])('未知语言 %p 不着色', info => {
    expect(codeLanguageFor(info)).toBeUndefined();
  });

  test('实时模式与源码模式都按语言着色，原文、撤销历史不变', async () => {
    const original = '前文\r\n\r\n```python\r\ndef 加(a, b):\r\n    # 注释\r\n    return "和" + 1\r\n```\r\n';
    const { view, read } = editor(original);
    await highlighted(view);
    expect(tokens(view, 'keyword')).toEqual(expect.arrayContaining(['def', 'return']));
    expect(tokens(view, 'comment')).toContain('# 注释');
    expect(tokens(view, 'string')).toContain('"和"');
    expect(tokens(view, 'number')).toContain('1');
    // 正文与围栏外不着色。
    expect(view.contentDOM.querySelector('.cm-line .cm-inkpot-token-keyword')?.closest('.cm-inkpot-code')).not.toBeNull();
    toggleSourceMode(view);
    expect(view.contentDOM.querySelector('.cm-inkpot-code')).toBeNull();
    expect(tokens(view, 'keyword')).toEqual(expect.arrayContaining(['def', 'return']));
    toggleSourceMode(view);
    expect(read()).toBe(original);
    expect(undoDepth(view.state)).toBe(0);
  });

  test('未知语言、缩进代码块与未闭合围栏保持原样', async () => {
    const { view } = editor('```unknown\nif x then y\n```\n\n    def indented():\n\n```python\ndef open():');
    await highlighted(view);
    await new Promise(resolve => setTimeout(resolve, 50));
    const lines = [...view.contentDOM.querySelectorAll('.cm-line')];
    expect(lines[1].querySelector('[class*="cm-inkpot-token-"]')).toBeNull();
    expect(lines.find(line => line.textContent.includes('indented'))?.querySelector('[class*="cm-inkpot-token-"]')).toBeNull();
  });

  test('多种语言在同一文档中各自着色，修改语言后重新着色', async () => {
    const { view } = editor('```js\nconst a = 1;\n```\n\n```go\nfunc main() {}\n```\n\n```sql\nSELECT 1;\n```');
    await highlighted(view);
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(tokens(view, 'keyword')).toEqual(expect.arrayContaining(['const', 'func', 'SELECT']));
    const info = view.state.doc.line(1);
    view.dispatch({ changes: { from: info.from + 3, to: info.to, insert: 'unknown' } });
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(tokens(view, 'keyword')).not.toContain('const');
  });

  test('代码块中的 Markdown 只着色，不触发列表续写，也不进入大纲层级', async () => {
    const text = '```markdown\n# 标题\n- 项目\n```';
    const { view } = editor(text, text.indexOf('项目') + 2);
    await highlighted(view);
    expect(tokens(view, 'tag')).toContain('# 标题');
    view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
    expect(view.state.doc.toString()).toBe('```markdown\n# 标题\n- 项目\n\n```');
  });

  test('组合输入期间不重建着色，结束后刷新', async () => {
    const { view } = editor('```js\nconst a = 1;\n```');
    await highlighted(view);
    const before = view.contentDOM.querySelector('.cm-inkpot-token-keyword');
    expect(before).not.toBeNull();
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    expect(view.compositionStarted).toBe(true);
    view.dispatch({ changes: { from: view.state.doc.line(2).from, insert: 'let ' } });
    expect(tokens(view, 'keyword')).toEqual(['const']);
    view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 150));
    expect(tokens(view, 'keyword')).toEqual(expect.arrayContaining(['let', 'const']));
  });
});
