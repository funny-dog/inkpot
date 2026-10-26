import type { EditorFonts } from './fonts';
import type { Heading } from './outline';
import type { DocumentStats } from './stats';
import type { PairingPreferences } from './typing';

/** 网页发往宿主的完整协议；保留既有字段，两端均按 generation 丢弃旧文档消息。 */
export type HostMessage =
  // 网页接口已安装，宿主此时可以配置资源并打开文档。
  | { ready: true }
  | { pasteImage: true; generation: number }
  | { openLink: string; generation: number }
  | { shortcut: string; generation: number }
  | { response: true; requestId: number; snapshot?: { text: string; revision: number }; value?: string; error?: string }
  // headings 为 undefined 时只更新当前标题；active 为 null 表示没有当前标题。
  | { outline: true; headings: Heading[] | undefined; active: number | null; revision: number; generation: number }
  // 状态通知不携带正文；需要保存时由宿主调用 snapshot 取得最新文本。
  | {
    changed: boolean;
    revision: number;
    generation: number;
    canUndo: boolean;
    canRedo: boolean;
    searchInputFocused: boolean;
    tableCellFocused: boolean;
    tableActions: string[];
    stats: DocumentStats;
    editorFocused: boolean;
    sourceMode: boolean;
    composing: boolean;
  };

export interface ResourceBases {
  /** 离线脚本、样式与字体的目录地址，以 / 结尾。 */
  assetBase: string;
  /** 宿主图片处理入口；后接编码后的完整路径及 document/revision 查询参数。 */
  imageBase: string;
}

export let assetBase = 'inkpot-asset://math/';
export let imageBase = 'inkpot-image://local/';

function directoryBase(value: string, protocol: string) {
  const url = new URL(value);
  if (!['https:', 'http:', protocol].includes(url.protocol) || url.host === '' || !url.pathname.endsWith('/')
    || url.search !== '' || url.hash !== '' || url.username !== '' || url.password !== '') {
    throw new Error('资源地址必须是无凭据、查询参数或片段的绝对目录 URL。');
  }
  return url.href;
}

/** 宿主应在首次 open 前配置；不传的目录保留现值，macOS 无须调用。 */
export function configureResources(options: Partial<ResourceBases>) {
  const assets = directoryBase(options.assetBase ?? assetBase, 'inkpot-asset:');
  const images = directoryBase(options.imageBase ?? imageBase, 'inkpot-image:');
  assetBase = assets;
  imageBase = images;
}

/** 宿主调用的网页接口；位置、列和长度按 UTF-16 计，行号从 1 开始。 */
export interface InkpotAPI {
  configure: (options: Partial<ResourceBases>) => void;
  /** 替换文档并清空撤销历史；generation 由宿主递增，随后消息携带该值。 */
  open: (text: string, generation?: number, dark?: boolean, language?: string) => void;
  navigateHeading: (id: number) => void;
  navigateFragment: (fragment: string) => void;
  selectMatch: (line: number, column: number, length: number) => void;
  insertImage: (path: string) => void;
  refreshImages: () => void;
  /** 未就绪或输入法候选尚未确认时抛错；文本保留原始行尾。 */
  snapshot: () => { text: string; revision: number };
  command: (name: string) => void;
  setAppearance: (dark: boolean) => void;
  setDisplayModes: (modes: { focus?: boolean; typewriter?: boolean }) => void;
  setFonts: (fonts: EditorFonts) => void;
  setEditingPreferences: (preferences: PairingPreferences & { remoteImages: boolean; indent?: number }) => void;
  selectedMarkdown: () => string;
  pastePlainText: (text: string) => void;
  pasteHTML: (html: string, plain: string) => void;
  setSpellcheck: (enabled: boolean) => void;
  /** pdf 保留离线 KaTeX 样式，其他值导出独立 HTML；失败时拒绝 Promise。 */
  exportHTML: (mode?: string) => Promise<string>;
}

/** WebView2 入站协议：大文本经结构化消息传递，不拼入脚本字符串。 */
export type HostRequest = { requestId: number } & (
  | { method: 'open'; text: string; generation: number; dark: boolean; language: string; resources: ResourceBases }
  | { method: 'snapshot' }
  | { method: 'command'; name: string }
  | { method: 'pastePlainText'; text: string }
  | { method: 'setAppearance'; dark: boolean }
  | { method: 'preferences'; fonts: EditorFonts; editing: PairingPreferences & { remoteImages: boolean; indent: number }; modes: { focus: boolean; typewriter: boolean }; spellcheck: boolean; zoom: number; zoomWithControlScroll: boolean }
  | { method: 'setFonts'; fonts: EditorFonts }
  | { method: 'setDisplayModes'; modes: { focus: boolean; typewriter: boolean } }
  | { method: 'setEditingPreferences'; preferences: PairingPreferences & { remoteImages: boolean; indent: number } }
  | { method: 'navigateHeading'; id: number }
  | { method: 'navigateFragment'; fragment: string }
  | { method: 'selectMatch'; line: number; column: number; length: number }
  | { method: 'insertImage'; path: string }
  | { method: 'refreshImages' | 'selectedMarkdown' }
  | { method: 'pasteHTML'; html: string; plain: string }
  | { method: 'exportHTML'; mode: string }
);

type HostChannel = { postMessage: (message: HostMessage) => void };

declare global {
  interface Window {
    inkpot: InkpotAPI;
    webkit?: { messageHandlers?: { document?: HostChannel } };
    chrome?: { webview?: HostChannel & { addEventListener?: (type: 'message', listener: (event: { data: unknown }) => void) => void } };
  }
}

/** WebKit 优先；WebView2 使用原生对象消息，由宿主反序列化，无须手动 JSON 编码。 */
export function postToHost(message: HostMessage) {
  const webkit = window.webkit?.messageHandlers?.document;
  if (webkit !== undefined) webkit.postMessage(message);
  else window.chrome?.webview?.postMessage(message);
}

/** 只接受明确列出的宿主操作；错误返回给请求方，保存失败不会伪装为成功。 */
export function listenToHost(api: InkpotAPI) {
  let generation = 0;
  let zoomWithControlScroll = false;
  if (window.chrome?.webview?.addEventListener === undefined) return;
  document.addEventListener('wheel', event => {
    if (!event.ctrlKey) return;
    event.preventDefault();
    if (zoomWithControlScroll && event.deltaY !== 0) postToHost({ shortcut: event.deltaY < 0 ? 'zoomIn' : 'zoomOut', generation });
  }, { passive: false });
  document.addEventListener('keydown', event => {
    if (event.isComposing) return;
    const key = event.key.toLowerCase();
    const plain: Record<string, string> = { F8: 'focus', F9: 'typewriter', F11: 'fullscreen', F3: event.shiftKey ? 'findPrevious' : 'findNext' };
    const control: Record<string, string> = { n: event.altKey ? 'newTab' : 'new', o: event.altKey ? 'openFolder' : event.shiftKey ? 'outline' : 'open',
      s: event.shiftKey ? 'saveAs' : 'save', w: 'close', ',': 'settings', f: 'folderSearch', e: 'files', m: 'source',
      tab: event.shiftKey ? 'previousTab' : 'nextTab', p: event.shiftKey ? 'pageSetup' : 'print', v: 'pastePlain',
      '0': 'resetZoom', '=': 'zoomIn', '+': 'zoomIn', '-': 'zoomOut' };
    const shiftOnly = ['f', 'e', 'm', 'v'];
    const shortcut = event.ctrlKey ? (shiftOnly.includes(key) && !event.shiftKey ? undefined : control[key]) : plain[event.key];
    if (shortcut === undefined) return;
    event.preventDefault();
    postToHost({ shortcut, generation });
  });
  window.chrome.webview.addEventListener('message', async ({ data }) => {
    if (typeof data !== 'object' || data === null || !('requestId' in data)
      || typeof data.requestId !== 'number' || !Number.isSafeInteger(data.requestId) || data.requestId < 1) return;
    const request = data as Partial<HostRequest>;
    try {
      switch (request.method) {
        case 'open':
          if (typeof request.text !== 'string' || typeof request.generation !== 'number' || !Number.isSafeInteger(request.generation)
            || request.generation < 0 || typeof request.dark !== 'boolean' || typeof request.language !== 'string'
            || typeof request.resources?.assetBase !== 'string' || typeof request.resources.imageBase !== 'string') throw new Error('无效的打开文档消息。');
          api.configure(request.resources);
          api.open(request.text, request.generation, request.dark, request.language);
          generation = request.generation;
          break;
        case 'snapshot':
          postToHost({ response: true, requestId: data.requestId, snapshot: api.snapshot() });
          return;
        case 'command':
          if (typeof request.name !== 'string') throw new Error('无效的编辑命令。');
          api.command(request.name);
          break;
        case 'pastePlainText':
          if (typeof request.text !== 'string') throw new Error('无效的粘贴文本。');
          api.pastePlainText(request.text);
          break;
        case 'setAppearance':
          if (typeof request.dark !== 'boolean') throw new Error('无效的外观消息。');
          api.setAppearance(request.dark);
          break;
        case 'preferences': {
          const { fonts, editing, modes } = request;
          if (fonts === undefined || typeof fonts.bodyFamily !== 'string' || typeof fonts.codeFamily !== 'string'
            || !Number.isFinite(fonts.bodySize) || !Number.isFinite(fonts.codeSize)
            || editing === undefined || typeof editing.brackets !== 'boolean' || typeof editing.markdown !== 'boolean'
            || typeof editing.remoteImages !== 'boolean' || ![2, 4].includes(editing.indent)
            || modes === undefined || typeof modes.focus !== 'boolean' || typeof modes.typewriter !== 'boolean'
            || typeof request.spellcheck !== 'boolean' || typeof request.zoom !== 'number' || !Number.isFinite(request.zoom) || request.zoom < .5 || request.zoom > 2
            || typeof request.zoomWithControlScroll !== 'boolean') throw new Error('无效的偏好设置。');
          api.setFonts(fonts); api.setEditingPreferences(editing); api.setDisplayModes(modes); api.setSpellcheck(request.spellcheck);
          document.body.style.zoom = String(request.zoom);
          zoomWithControlScroll = request.zoomWithControlScroll;
          break;
        }
        case 'setFonts': {
          const fonts = request.fonts as EditorFonts | null | undefined;
          if (fonts === undefined || fonts === null || typeof fonts.bodyFamily !== 'string' || typeof fonts.codeFamily !== 'string'
            || ![fonts.bodySize, fonts.codeSize].every(size => typeof size === 'number' && Number.isFinite(size) && size >= 8 && size <= 72)) throw new Error('无效的字体设置。');
          api.setFonts(fonts);
          break;
        }
        case 'setDisplayModes':
          if (typeof request.modes?.focus !== 'boolean' || typeof request.modes.typewriter !== 'boolean') throw new Error('无效的显示模式。');
          api.setDisplayModes(request.modes);
          break;
        case 'setEditingPreferences': {
          const preferences = request.preferences;
          if (typeof preferences?.brackets !== 'boolean' || typeof preferences.markdown !== 'boolean' || typeof preferences.remoteImages !== 'boolean'
            || ![2, 4].includes(preferences.indent)) throw new Error('无效的编辑设置。');
          api.setEditingPreferences(preferences);
          break;
        }
        case 'navigateHeading':
          if (typeof request.id !== 'number' || !Number.isSafeInteger(request.id) || request.id < 0) throw new Error('无效的标题。');
          api.navigateHeading(request.id as number); break;
        case 'navigateFragment':
          if (typeof request.fragment !== 'string') throw new Error('无效的锚点。');
          api.navigateFragment(request.fragment); break;
        case 'selectMatch':
          if (![request.line, request.column, request.length].every(value => Number.isSafeInteger(value) && (value as number) >= 0)) throw new Error('无效的位置。');
          api.selectMatch(request.line as number, request.column as number, request.length as number); break;
        case 'insertImage':
          if (typeof request.path !== 'string') throw new Error('无效的图片路径。');
          api.insertImage(request.path); break;
        case 'refreshImages': api.refreshImages(); break;
        case 'selectedMarkdown':
          postToHost({ response: true, requestId: data.requestId, value: api.selectedMarkdown() }); return;
        case 'pasteHTML':
          if (typeof request.html !== 'string' || typeof request.plain !== 'string') throw new Error('无效的剪贴板内容。');
          api.pasteHTML(request.html, request.plain); break;
        case 'exportHTML':
          if (!['html', 'pdf'].includes(request.mode ?? '')) throw new Error('无效的导出格式。');
          postToHost({ response: true, requestId: data.requestId, value: await api.exportHTML(request.mode) });
          return;
        case undefined:
        default: throw new Error('未知的宿主操作。');
      }
      postToHost({ response: true, requestId: data.requestId });
    } catch (error) {
      postToHost({ response: true, requestId: data.requestId, error: error instanceof Error ? error.message : '编辑器操作失败。' });
    }
  });
}
