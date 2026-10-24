import { useLanguageModulesForTests } from '../../editor/code-languages';

// jsdom 缺少的浏览器能力；编辑器模块与真实 WKWebView 使用相同的依赖。
(window as unknown as { webkit: unknown }).webkit = { messageHandlers: {} };

globalThis.ResizeObserver = class {
  observe() { /* 无实际布局。 */ }
  unobserve() { /* 无实际布局。 */ }
  disconnect() { /* 无实际布局。 */ }
} as unknown as typeof ResizeObserver;

Range.prototype.getClientRects = function () {
  return [] as unknown as DOMRectList;
};

Element.prototype.scrollTo = function () { /* 无实际滚动。 */ };
window.matchMedia = () => ({
  matches: false,
  addEventListener() { /* 无系统外观事件。 */ },
  removeEventListener() { /* 无系统外观事件。 */ },
}) as unknown as MediaQueryList;

if (typeof globalThis.DragEvent === 'undefined') {
  (globalThis as Record<string, unknown>).DragEvent = class DragEvent extends Event {} as unknown as typeof DragEvent;
}

// 代码语言文件在应用中经 inkpot-asset:// 加载，测试直接读取同一份 legacy-modes。
useLanguageModulesForTests(file => import(`@codemirror/legacy-modes/mode/${file}`));
