import { afterEach, describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { openSearchPanel } from '@codemirror/search';
import { writingExtensions } from '../editor/writing';
import { liveEditing } from '../editor/live';
import { welcomeHints } from '../editor/welcome';
import { editorLanguage, setEditorLanguage, t } from '../editor/localization';
import { documentHTML } from '../editor/export';
import { tableCommands } from '../editor/table';

const views: EditorView[] = [];
afterEach(() => {
  for (const view of views.splice(0)) view.destroy();
  setEditorLanguage('zh-Hans');
});

function editor(text: string) {
  const view = new EditorView({ parent: document.body, state: EditorState.create({
    doc: text, extensions: [...writingExtensions, ...liveEditing, welcomeHints],
  }) });
  views.push(view);
  return view;
}

describe('编辑器双语界面', () => {
  test.each([
    ['zh-Hans', '开始写作…', '查找文本', '完成', 'Markdown 表格', '第 1 行，第 1 列'],
    ['en', 'Start writing…', 'Find', 'Done', 'Markdown table', 'Row 1, column 1'],
  ])('%s 的查找栏、快捷键和表格无障碍文案', (language, placeholder, find, done, table, cell) => {
    setEditorLanguage(language);
    expect(t('开始写作…')).toBe(placeholder);
    const empty = editor('');
    expect(empty.dom.querySelector('.cm-inkpot-welcome dd')?.textContent).toBe(language === 'en' ? 'Open File' : '打开文件');
    const text = '\n\n| 标题 | English |\n| --- | --- |\n| 中文 | unchanged |\n\n';
    const view = editor(text);
    expect(view.dom.querySelector('table')?.getAttribute('aria-label')).toBe(table);
    expect(view.dom.querySelector('.cm-inkpot-table-input')?.getAttribute('aria-label')).toBe(cell);
    openSearchPanel(view);
    expect(view.dom.querySelector('input[name=search]')?.getAttribute('placeholder')).toBe(find);
    expect(view.dom.querySelector('button[name=close]')?.textContent).toBe(done);
    expect(view.state.doc.toString()).toBe(text);
    expect(document.documentElement.lang).toBe(language);
  });

  test('参数只替换模板，不二次解释用户内容', () => {
    setEditorLanguage('en');
    expect(t('无法导出图片“{0}”：{1}', '中文{1}.png', '错误{0}')).toBe('Unable to export image “中文{1}.png”: 错误{0}');
    setEditorLanguage('zh-Hans');
    expect(t('第 {0} 行，第 {1} 列', 2, 3)).toBe('第 2 行，第 3 列');
  });

  test('英文界面新建表格使用英文列名', () => {
    setEditorLanguage('en');
    const view = editor('');
    view.focus();
    expect(tableCommands.insertTable(view)).toBe(true);
    expect(view.state.doc.toString()).toContain('| Column 1 | Column 2 |');
  });

  test('其他系统语言回退英语，中文变体沿用简体界面', () => {
    setEditorLanguage('fr');
    expect(editorLanguage()).toBe('en');
    expect(t('完成')).toBe('Done');
    setEditorLanguage('zh-CN');
    expect(editorLanguage()).toBe('zh-Hans');
  });

  test('英文界面导出仍保留中文正文和用户标题', async () => {
    setEditorLanguage('en');
    const view = editor('# 中文标题\n\n中文正文 English text\n');
    const html = await documentHTML(view);
    expect(html).toContain('<title>中文标题</title>');
    expect(html).toContain('中文正文 English text');
    expect(view.state.doc.toString()).toBe('# 中文标题\n\n中文正文 English text\n');
  });
});
