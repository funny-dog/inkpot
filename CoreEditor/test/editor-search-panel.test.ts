import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { openSearchPanel } from '@codemirror/search';
import { writingExtensions } from '../editor/writing';

const views: EditorView[] = [];
afterEach(() => { for (const view of views.splice(0)) view.destroy(); });

function editor(text: string) {
  const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: text, extensions: writingExtensions }) });
  views.push(view);
  return view;
}

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

  test('输入关键词并切换匹配项时实时更新匹配计数', () => {
    const view = editor('苹果 香蕉 苹果 橘子 苹果');
    openSearchPanel(view);
    const input = view.dom.querySelector<HTMLInputElement>('.cm-inkpot-search input[name=search]');
    const status = view.dom.querySelector<HTMLElement>('.cm-inkpot-search [role=status]');
    const nextButton = view.dom.querySelector<HTMLButtonElement>('.cm-inkpot-search button[name=next]');
    if (input === null || status === null || nextButton === null) throw new Error('查找面板控件缺失');
    input.value = '苹果';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    expect(status.textContent).toBe('3');
    nextButton.click();
    expect(status.textContent).toBe('1 / 3');
    nextButton.click();
    expect(status.textContent).toBe('2 / 3');
  });
});
