import { afterEach, describe, expect, test } from '@jest/globals';
import process from 'node:process';
import { EditorState, StateEffect } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { ensureSyntaxTree } from '@codemirror/language';
import { Config } from '../src/config';
import { liveModeExtension, setLiveMode } from '../src/wysiwyg';
import { setUp } from './utils/editor';

const source = '# 标题\n\n**粗体** *斜体* ~~删除~~ `code`\n\n- 项目\n- [ ] 任务\n\n> 引用\n\n[链接](https://example.com)\n\n![图片](image.png)\n\n---\n\n```js\nconst x = 1;\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n$$x^2$$\n\n[^1]: 脚注\n';

afterEach(() => window.editor.destroy());

function createEditor(text = source) {
  window.config = { liveMode: true } as Config;
  setUp(text, liveModeExtension());
}

describe('实时模式', () => {
  test('打开、移动选区和切换模式不修改原文或发出文档修改', () => {
    createEditor();
    let changes = 0;
    window.editor.dispatch({ effects: StateEffect.appendConfig.of(EditorView.updateListener.of(update => {
      if (update.docChanged) changes++;
    })) });
    for (const anchor of [5, 15, source.indexOf('任务'), source.length]) {
      window.editor.dispatch({ selection: { anchor } });
      setLiveMode(false);
      setLiveMode(true);
    }
    expect(window.editor.state.doc.toString()).toBe(source);
    expect(changes).toBe(0);
  });

  test('标题外隐藏标记，光标进入标题时恢复源码', () => {
    createEditor('# 标题\n\n正文');
    expect(window.editor.dom.querySelector('.cm-md-syntaxHiddenSource')).toBeNull();
    window.editor.dispatch({ selection: { anchor: 8 } });
    expect(window.editor.dom.querySelector('.cm-md-syntaxHiddenSource')?.textContent).toBe('# ');
    window.editor.dispatch({ selection: { anchor: 2 } });
    expect(window.editor.dom.querySelector('.cm-md-syntaxHiddenSource')).toBeNull();
  });

  test('初始化前可记录配置，默认开启且显式关闭生效', () => {
    window.editor = document.createElement('div') as unknown as EditorView;
    window.config = {} as Config;
    expect(() => setLiveMode(false)).not.toThrow();
    setUp('# 标题\n\n正文', liveModeExtension());
    expect(window.editor.dom.classList.contains('cm-md-syntaxHiddenMode')).toBe(false);
    setLiveMode(true);
    expect(window.editor.dom.classList.contains('cm-md-syntaxHiddenMode')).toBe(true);
  });

  test('5000 行文档的装饰计算基线', () => {
    const text = Array.from({ length: 1000 }, () => '# 标题\n\n**文字** [链接](https://example.com)\n\n- 项目').join('\n');
    createEditor(text);
    ensureSyntaxTree(window.editor.state, text.length, 5000);
    const start = performance.now();
    for (let index = 0; index < 10; index++) {
      window.editor.dispatch({ selection: { anchor: index } });
    }
    process.stdout.write(`实时模式 5000 行选区装饰更新均值：${((performance.now() - start) / 10).toFixed(2)}ms\n`);
    expect(window.editor.state.doc.toString()).toBe(text);
  });
});



test('CRLF 与 BOM 经实时模式切换后按原换行符导出', () => {
  const source = '\uFEFF# 标题\r\n\r\n|A|B|\r\n|---|---|\r\n|1|2|\r\n';
  window.config = { liveMode: true } as Config;
  setUp(source, [EditorState.lineSeparator.of('\r\n'), liveModeExtension()]);
  setLiveMode(false);
  setLiveMode(true);
  expect(window.editor.state.sliceDoc()).toBe(source);
});
