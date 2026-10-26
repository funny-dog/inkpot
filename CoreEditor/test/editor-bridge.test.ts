import { afterEach, describe, expect, jest, test } from '@jest/globals';
import { EditorView } from '@codemirror/view';
import { assetBase, imageBase, configureResources, listenToHost, postToHost, type HostMessage, type InkpotAPI } from '../editor/bridge';

const defaults = { assetBase, imageBase };
const originalWebkit = window.webkit;
const originalChrome = window.chrome;
afterEach(() => {
  window.webkit = originalWebkit;
  window.chrome = originalChrome;
  configureResources(defaults);
});

const messages: HostMessage[] = [
  { ready: true },
  { pasteImage: true, generation: 7 },
  { openLink: 'https://example.com/中文', generation: 7 },
  { outline: true, headings: [{ id: 0, from: 0, to: 4, level: 1, title: '标题' }], active: 0, revision: 2, generation: 7 },
  { outline: true, headings: undefined, active: null, revision: 2, generation: 7 },
  { changed: true, revision: 2, generation: 7, canUndo: true, canRedo: false, searchInputFocused: false,
    tableCellFocused: false, tableActions: [], stats: { words: 2, characters: 2, lines: 1 },
    editorFocused: true, sourceMode: false, composing: false },
];

describe('Inkpot 宿主桥接', () => {
  test('Windows 偏好、导航与异步导出通过结构化消息传递，失败返回错误', async () => {
    const postMessage = jest.fn();
    let receive: ((event: { data: unknown }) => void) | undefined;
    window.webkit = undefined;
    window.chrome = { webview: { postMessage, addEventListener: (_type, listener) => { receive = listener; } } };
    const api = { setFonts: jest.fn(), setEditingPreferences: jest.fn(), setDisplayModes: jest.fn(), setSpellcheck: jest.fn(),
      navigateHeading: jest.fn(), navigateFragment: jest.fn(), selectMatch: jest.fn(), insertImage: jest.fn(),
      selectedMarkdown: jest.fn(() => '**选区**'), exportHTML: jest.fn(async () => '<html>内嵌资源</html>') };
    listenToHost(api as unknown as InkpotAPI);
    if (receive === undefined) throw new Error('未安装监听器');
    const preferences = { method: 'preferences', fonts: { bodyFamily: '等线', bodySize: 16, codeFamily: 'Consolas', codeSize: 14 },
      editing: { brackets: false, markdown: true, remoteImages: false, indent: 4 }, modes: { focus: true, typewriter: true },
      spellcheck: false, zoom: 1.2, zoomWithControlScroll: true };
    await receive({ data: { requestId: 11, ...preferences } });
    expect(api.setFonts).toHaveBeenCalledWith(preferences.fonts);
    expect(api.setSpellcheck).toHaveBeenCalledWith(false);
    expect(document.body.style.zoom).toBe('1.2');
    await receive({ data: { requestId: 12, ...preferences, zoom: 'bad' } });
    expect(postMessage).toHaveBeenLastCalledWith(expect.objectContaining({ requestId: 12, error: expect.any(String) }));
    expect(api.setFonts).toHaveBeenCalledTimes(1);
    await receive({ data: { requestId: 13, method: 'selectMatch', line: 2, column: 5, length: 6 } });
    expect(api.selectMatch).toHaveBeenCalledWith(2, 5, 6);
    await receive({ data: { requestId: 14, method: 'selectedMarkdown' } });
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 14, value: '**选区**' });
    await receive({ data: { requestId: 15, method: 'exportHTML', mode: 'html' } });
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 15, value: '<html>内嵌资源</html>' });
    api.exportHTML.mockImplementation(async () => { throw new Error('图片读取失败'); });
    await receive({ data: { requestId: 16, method: 'exportHTML', mode: 'pdf' } });
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 16, error: '图片读取失败' });
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ',', ctrlKey: true }));
    expect(postMessage).toHaveBeenLastCalledWith({ shortcut: 'settings', generation: 0 });
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'F8' }));
    expect(postMessage).toHaveBeenLastCalledWith({ shortcut: 'focus', generation: 0 });
    document.body.style.removeProperty('zoom');
  });

  test('WebView2 结构化请求传递大文本、返回快照、报告错误并拒绝非法操作', () => {
    const postMessage = jest.fn();
    let receive: ((event: { data: unknown }) => void) | undefined;
    window.webkit = undefined;
    window.chrome = { webview: { postMessage, addEventListener: (_type, listener) => { receive = listener; } } };
    const api = { configure: jest.fn(), open: jest.fn(), command: jest.fn(), setAppearance: jest.fn(), pastePlainText: jest.fn(),
      navigateHeading: jest.fn(), setFonts: jest.fn(), setEditingPreferences: jest.fn(), setDisplayModes: jest.fn(),
      snapshot: jest.fn(() => ({ text: '中文\r\n尾', revision: 3 })) };
    listenToHost(api as unknown as InkpotAPI);
    if (receive === undefined) throw new Error('未安装入站监听器');
    const text = '\\` ${literal} </script> 中文\r\n'.repeat(50000);
    const resources = { assetBase: 'https://editor.inkpot.local/math/', imageBase: 'https://images.inkpot.local/local/' };
    receive({ data: { requestId: 1, method: 'open', text, generation: 9, dark: true, language: 'zh-Hans', resources } });
    expect(api.configure).toHaveBeenCalledWith(resources);
    expect(api.open).toHaveBeenCalledWith(text, 9, true, 'zh-Hans');
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 1 });
    receive({ data: { requestId: 2, method: 'snapshot' } });
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 2, snapshot: { text: '中文\r\n尾', revision: 3 } });
    receive({ data: { requestId: 3, method: 'command', name: 'undo' } });
    expect(api.command).toHaveBeenCalledWith('undo');
    receive({ data: { requestId: 4, method: 'setAppearance', dark: false } });
    expect(api.setAppearance).toHaveBeenCalledWith(false);
    receive({ data: { requestId: 5, method: 'pastePlainText', text: '粘贴\r\n原文' } });
    expect(api.pastePlainText).toHaveBeenCalledWith('粘贴\r\n原文');
    const fonts = { bodyFamily: '微软雅黑', bodySize: 18, codeFamily: 'Consolas', codeSize: 14 };
    const preferences = { brackets: false, markdown: true, remoteImages: false, indent: 4 };
    receive({ data: { requestId: 8, method: 'setFonts', fonts } });
    expect(api.setFonts).toHaveBeenCalledWith(fonts);
    receive({ data: { requestId: 9, method: 'setEditingPreferences', preferences } });
    expect(api.setEditingPreferences).toHaveBeenCalledWith(preferences);
    receive({ data: { requestId: 10, method: 'setDisplayModes', modes: { focus: true, typewriter: false } } });
    expect(api.setDisplayModes).toHaveBeenCalledWith({ focus: true, typewriter: false });
    receive({ data: { requestId: 11, method: 'navigateHeading', id: 0 } });
    expect(api.navigateHeading).toHaveBeenCalledWith(0);
    api.snapshot.mockImplementation(() => { throw new Error('尚未确认候选'); });
    receive({ data: { requestId: 6, method: 'snapshot' } });
    expect(postMessage).toHaveBeenLastCalledWith({ response: true, requestId: 6, error: '尚未确认候选' });
    for (const request of [{ method: 'open', text: 1 }, { method: 'command', name: false },
      { method: 'pastePlainText', text: 1 }, { method: 'setAppearance', dark: 'true' }, { method: 'constructor' },
      { method: 'navigateHeading', id: -1 }, { method: 'navigateHeading', id: 0.5 },
      { method: 'setFonts', fonts: null }, { method: 'setFonts', fonts: { ...fonts, bodySize: 100 } },
      { method: 'setFonts', fonts: { ...fonts, codeFamily: 123 } },
      { method: 'setDisplayModes', modes: { focus: 'true', typewriter: false } },
      { method: 'setEditingPreferences', preferences: { ...preferences, indent: 3 } },
      { method: 'setEditingPreferences', preferences: { ...preferences, brackets: null } }, {}]) {
      receive({ data: { ...request, requestId: 7 } });
      expect(postMessage).toHaveBeenLastCalledWith(expect.objectContaining({ response: true, requestId: 7, error: expect.any(String) }));
    }
    const count = postMessage.mock.calls.length;
    for (const data of [null, 'x', {}, { requestId: -1 }, { requestId: 1.5 }]) receive({ data });
    expect(postMessage).toHaveBeenCalledTimes(count);
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 's', ctrlKey: true, shiftKey: true }));
    expect(postMessage).toHaveBeenLastCalledWith({ shortcut: 'saveAs', generation: 9 });
    for (const [key, modifiers, shortcut] of [
      [',', { ctrlKey: true }, 'settings'], ['o', { ctrlKey: true, altKey: true }, 'openFolder'],
      ['e', { ctrlKey: true, shiftKey: true }, 'files'], ['o', { ctrlKey: true, shiftKey: true }, 'outline'],
      ['F8', {}, 'focus'], ['F9', {}, 'typewriter'],
    ] as const) {
      document.dispatchEvent(new KeyboardEvent('keydown', { key, ...modifiers }));
      expect(postMessage).toHaveBeenLastCalledWith({ shortcut, generation: 9 });
    }
    const beforeComposing = postMessage.mock.calls.length;
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ',', ctrlKey: true, isComposing: true }));
    expect(postMessage).toHaveBeenCalledTimes(beforeComposing);
  });

  test.each(['WebKit', 'WebView2'])('%s 原样发送全部消息', host => {
    const postMessage = jest.fn();
    window.webkit = host === 'WebKit' ? { messageHandlers: { document: { postMessage } } } : undefined;
    window.chrome = host === 'WebView2' ? { webview: { postMessage } } : undefined;
    for (const message of messages) postToHost(message);
    expect(postMessage.mock.calls).toEqual(messages.map(message => [message]));
    for (const [index, message] of messages.entries()) expect(postMessage.mock.calls[index][0]).toBe(message);
  });

  test('两通道同时存在时只发 WebKit，WebKit 通道不完整时回退 WebView2', () => {
    const webkit = jest.fn();
    const chrome = jest.fn();
    window.webkit = { messageHandlers: { document: { postMessage: webkit } } };
    window.chrome = { webview: { postMessage: chrome } };
    postToHost({ ready: true });
    expect(webkit).toHaveBeenCalledTimes(1);
    expect(chrome).not.toHaveBeenCalled();
    window.webkit = { messageHandlers: {} };
    postToHost({ ready: true });
    expect(chrome).toHaveBeenCalledWith({ ready: true });
  });

  test('无宿主通道时允许独立载入', () => {
    window.webkit = undefined;
    window.chrome = undefined;
    expect(() => postToHost({ ready: true })).not.toThrow();
  });

  test('默认资源地址与 macOS 原值一致，可独立配置 HTTPS 目录', () => {
    expect(defaults).toEqual({ assetBase: 'inkpot-asset://math/', imageBase: 'inkpot-image://local/' });
    configureResources({ assetBase: 'https://editor.inkpot.local/math/' });
    expect(assetBase).toBe('https://editor.inkpot.local/math/');
    expect(imageBase).toBe(defaults.imageBase);
    configureResources({ imageBase: 'https://images.inkpot.local/local/' });
    expect(imageBase).toBe('https://images.inkpot.local/local/');
    expect(assetBase).toBe('https://editor.inkpot.local/math/');
  });

  test.each(['relative/', 'https://editor.inkpot.local/math', 'https://editor.inkpot.local/math/?x=1',
    'https://editor.inkpot.local/math/#fragment', 'https://user:secret@editor.inkpot.local/', 'javascript:alert(1)',
  ])('拒绝不完整或不安全的资源目录且不部分更新：%s', invalidBase => {
    expect(() => configureResources({ assetBase: 'https://editor.inkpot.local/math/', imageBase: invalidBase })).toThrow();
    expect(assetBase).toBe(defaults.assetBase);
    expect(imageBase).toBe(defaults.imageBase);
  });

  test('完整编辑器的 ready、编辑与撤销经两种通道保留消息和原文行尾', async () => {
    const postMessage = jest.fn<(message: HostMessage) => void>();
    window.webkit = { messageHandlers: { document: { postMessage } } };
    await import('../editor/editor');
    expect(postMessage).toHaveBeenCalledWith({ ready: true });
    try {
      for (const host of ['WebKit', 'WebView2']) {
        window.webkit = host === 'WebKit' ? { messageHandlers: { document: { postMessage } } } : undefined;
        window.chrome = host === 'WebView2' ? { webview: { postMessage } } : undefined;
        postMessage.mockClear();
        window.inkpot.configure({});
        window.inkpot.open('# 标题\r\n中文\n尾', 7, false, 'zh-Hans');
        expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ changed: false, generation: 7, revision: 0 }));
        window.inkpot.pastePlainText('新');
        expect(postMessage).toHaveBeenCalledWith(expect.objectContaining({ changed: true, generation: 7, revision: 1, canUndo: true }));
        expect(window.inkpot.snapshot().text).toBe('新# 标题\r\n中文\n尾');
        window.inkpot.command('undo');
        expect(window.inkpot.snapshot()).toEqual({ text: '# 标题\r\n中文\n尾', revision: 2 });
        document.dispatchEvent(new CustomEvent('inkpot-open-link', { detail: 'https://example.com/' }));
        expect(postMessage).toHaveBeenCalledWith({ openLink: 'https://example.com/', generation: 7 });
      }
    } finally {
      const element = document.querySelector<HTMLElement>('.cm-editor');
      if (element !== null) EditorView.findFromDOM(element)?.destroy();
    }
  });
});
