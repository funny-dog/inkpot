import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { openSearchPanel } from '@codemirror/search';
import { writingExtensions } from '../editor/writing';
import { welcomeHints } from '../editor/welcome';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string) {
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: text, extensions: [...writingExtensions, welcomeHints] }) });
  views.push(view);
  return view;
}

describe('空文档快捷键提示', () => {
  test('只在文档为空时显示，输入后隐藏、清空后恢复', () => {
    const view = editor('');
    const hints = view.dom.querySelector<HTMLElement>('.cm-inkpot-welcome');
    expect(hints).not.toBeNull();
    expect(hints?.hidden).toBe(false);
    expect([...view.dom.querySelectorAll('.cm-inkpot-welcome dt')].map(node => node.textContent)).toEqual(['⌘O', '⌥⌘O', '⇧⌘M', '⌘,']);
    view.dispatch({ changes: { from: 0, insert: '字' } });
    expect(hints?.hidden).toBe(true);
    view.dispatch({ changes: { from: 0, to: 1 } });
    expect(hints?.hidden).toBe(false);
  });

  test('提示挂在编辑器根节点，不进入正文内容', () => {
    const view = editor('');
    expect(view.contentDOM.querySelector('.cm-inkpot-welcome')).toBeNull();
    expect(view.state.doc.toString()).toBe('');
  });

  test('非空文档打开时不显示', () => {
    const view = editor('# 标题');
    expect(view.dom.querySelector<HTMLElement>('.cm-inkpot-welcome')?.hidden).toBe(true);
  });
});

describe('查找栏结构', () => {
  test('按设计稿排列：输入框、选项、箭头按钮组与完成', () => {
    const view = editor('写作与写字');
    openSearchPanel(view);
    const panel = view.dom.querySelector('.cm-inkpot-search');
    const [first, second] = [...(panel?.children ?? [])];
    expect([...first.children].map(node => node.className)).toEqual([
      'cm-inkpot-search-field', 'cm-inkpot-search-options', 'cm-inkpot-search-divider', 'cm-inkpot-search-nav', 'cm-inkpot-search-spacer', 'cm-inkpot-search-action',
    ]);
    expect(first.querySelector('button[name=close]')?.textContent).toBe('完成');
    expect([...first.querySelectorAll('.cm-inkpot-search-nav button')].map(node => node.getAttribute('aria-label'))).toEqual(['上一个', '下一个']);
    expect([...first.querySelectorAll('.cm-inkpot-search-options input')].map(node => (node as HTMLInputElement).name)).toEqual(['caseSensitive', 'wholeWord', 'regexp']);
    expect(second.querySelector('.cm-inkpot-search-replace-field input[name=replace]')).not.toBeNull();
    expect([...second.querySelectorAll('.cm-inkpot-search-action')].map(node => node.textContent)).toEqual(['替换', '全部替换']);
  });
});
