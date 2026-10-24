import { EditorState } from '@codemirror/state';
import { Command, EditorView, keymap, placeholder } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, selectAll, undo, undoDepth, isolateHistory } from '@codemirror/commands';
import { sourceDocument } from './source';
import { writingExtensions } from './writing';
import { formatCommands } from './format';
import { searchCommands } from './search';
import { liveEditing, sourceMode, toggleSourceMode } from './live';
import { documentOutline } from './outline';
import { refreshImages, setImageDocument } from './image';
import { tableCommands, canTableCommand, syncTableSelection } from './table';
import { mathCommands } from './math';
import { documentStats, statsExtension } from './stats';
import { spellingExclusions } from './spelling';
import { documentHTML } from './export';
import { applyAppearance, appearanceExtensionsFor } from './theme';
import { applyDisplayModes, displayExtensions } from './focus';
import { isComposing } from './mode';
import { linkAt, linkNavigation } from './basic';
import { applyFonts, EditorFonts } from './fonts';
import { richPaste } from './paste';
import { welcomeHints } from './welcome';
import { searchPanelTheme } from './search';

declare const window: {
  inkpot: {
    open: (text: string, generation?: number, dark?: boolean) => void;
    navigateHeading: (id: number) => void;
    navigateFragment: (fragment: string) => void;
    selectMatch: (line: number, column: number, length: number) => void;
    insertImage: (path: string) => void;
    refreshImages: () => void;
    snapshot: () => { text: string; revision: number };
    command: (name: string) => void;
    setAppearance: (dark: boolean) => void;
    setDisplayModes: (modes: { focus?: boolean; typewriter?: boolean }) => void;
    setFonts: (fonts: EditorFonts) => void;
    exportHTML: (mode?: string) => Promise<string>;
  };
  webkit: { messageHandlers: { document: { postMessage: (message: unknown) => void } } };
};

let view: EditorView | undefined;
let source = sourceDocument('');
let revision = 0;
let generation = 0;
const outline = documentOutline((headings, active) => {
  window.webkit.messageHandlers.document.postMessage({ outline: true, headings, active, revision, generation });
});
const commands: Readonly<Partial<Record<string, Command>>> = { focus: view => { view.focus(); return true; }, undo, redo, selectAll, toggleSourceMode, ...formatCommands, ...searchCommands, ...tableCommands, ...mathCommands };

function publish(changed: boolean) {
  if (view === undefined) return;
  window.webkit.messageHandlers.document.postMessage({
    changed,
    revision,
    generation,
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
    searchInputFocused: document.activeElement instanceof HTMLInputElement && !document.activeElement.matches('.cm-inkpot-table-input'),
    tableCellFocused: document.activeElement?.matches('.cm-inkpot-table-input') === true,
    tableActions: Object.keys(tableCommands).filter(name => view !== undefined && canTableCommand(name, view)),
    stats: documentStats(view.state),
    editorFocused: view.contentDOM.contains(document.activeElement),
    sourceMode: view.state.field(sourceMode),
    composing: isComposing(view),
  });
}

document.addEventListener('focusin', () => queueMicrotask(() => publish(false)));
for (const event of ['compositionstart', 'compositionend']) document.addEventListener(event, () => queueMicrotask(() => publish(false)));
document.addEventListener('inkpot-open-link', event => {
  if (view !== undefined && !isComposing(view)) window.webkit.messageHandlers.document.postMessage({ openLink: (event as CustomEvent<string>).detail, generation });
});
document.addEventListener('focusout', () => queueMicrotask(() => publish(false)));

window.inkpot = {
  open(text, documentGeneration = 0, dark = false) {
    generation = documentGeneration;
    setImageDocument(generation);
    view?.destroy();
    source = sourceDocument(text);
    revision = 0;
    view = new EditorView({
      parent: document.body,
      state: EditorState.create({
        doc: source.doc,
        extensions: [
          ...source.extensions,
          ...displayExtensions(),
          statsExtension,
          ...writingExtensions,
          ...liveEditing,
          ...appearanceExtensionsFor(dark),
          outline.extension,
          EditorView.domEventHandlers({ paste(event) {
            if (![...(event.clipboardData?.files ?? [])].some(file => file.type.startsWith('image/'))) return false;
            event.preventDefault();
            window.webkit.messageHandlers.document.postMessage({ pasteImage: true, generation });
            return true;
          } }),
          richPaste,
          linkNavigation(destination => window.webkit.messageHandlers.document.postMessage({ openLink: destination, generation })),
          keymap.of([{ key: 'Mod-Enter', run: view => {
            if (isComposing(view)) return true;
            const destination = linkAt(view, view.state.selection.main.head);
            if (destination === undefined) return false;
            window.webkit.messageHandlers.document.postMessage({ openLink: destination, generation });
            return true;
          } }]),
          history(),
          keymap.of([...historyKeymap, ...defaultKeymap]),
          EditorView.lineWrapping,
          // 拼写检查的开关由原生“输入时检查拼写”控制；自动纠正、首字母大写保持 CodeMirror 默认关闭，不改写原文。
          EditorView.contentAttributes.of({ 'aria-label': 'Markdown 文本编辑器', spellcheck: 'true' }),
          spellingExclusions,
          placeholder('开始写作…'),
          welcomeHints,
          EditorView.updateListener.of(update => {
            if (update.docChanged) {
              revision++;
              publish(true);
            } else if (update.selectionSet || update.startState.field(sourceMode) !== update.state.field(sourceMode)) {
              publish(false);
            }
          }),
          EditorView.theme({
            '&': { height: '100%' },
            '.cm-scroller': { overflow: 'auto', fontFamily: 'var(--inkpot-code-font, Menlo, monospace)', fontSize: 'var(--inkpot-code-size, 15px)', lineHeight: '1.75' },
            // 正文限制在约 45 个汉字宽并居中；em 随正文/代码字号缩放，窄窗口时退回铺满。
            '.cm-content': { padding: '44px 48px', minHeight: '100%', maxWidth: 'calc(45em + 96px)', margin: '0 auto' },
            '&.cm-focused': { outline: 'none' },
            '.cm-panels': { backgroundColor: '#f7f7f8', color: '#1d1d1f' },
            '.cm-panels.cm-panels-top': { borderBottom: '1px solid rgba(0, 0, 0, 0.09)' },
            ...searchPanelTheme,
          }),
        ],
      }),
    });
    view.focus();
    publish(false);
  },
  navigateHeading(id) {
    if (view !== undefined) outline.navigate(view, id);
  },
  navigateFragment(fragment) {
    if (view === undefined) return;
    const plugin = view.plugin(outline.extension);
    plugin?.refresh();
    const counts = new Map<string, number>();
    const target = plugin?.items.find(item => {
      const slug = item.title.toLowerCase().replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/\s/g, '-');
      const count = counts.get(slug) ?? 0;
      counts.set(slug, count + 1);
      return (count === 0 ? slug : `${slug}-${count}`) === fragment;
    });
    if (target !== undefined) outline.navigate(view, target.id);
  },
  // 文件夹搜索结果定位：行号从 1 开始，列与长度按行内的 UTF-16 偏移计。文件已在磁盘上变化时按当前内容就近定位。
  selectMatch(line, column, length) {
    if (view === undefined || line < 1 || line > view.state.doc.lines) return;
    const target = view.state.doc.line(line);
    const from = Math.min(target.to, target.from + column);
    const head = Math.min(target.to, from + length);
    view.dispatch({
      selection: { anchor: from, head },
      effects: EditorView.scrollIntoView(from, { y: 'center' }),
    });
    view.focus();
  },
  insertImage(path) {
    if (view === undefined || isComposing(view) || view.state.readOnly) throw new Error('请先结束输入或等待编辑器就绪，再插入图片。');
    view.dispatch(view.state.update({ ...view.state.replaceSelection(`![图片](${path})`), annotations: isolateHistory.of('full'), userEvent: 'input.image', scrollIntoView: true }));
    view.focus();
  },
  refreshImages() { view?.dispatch({ effects: refreshImages.of(null) }); },
  setFonts(fonts) { if (view !== undefined) applyFonts(view, fonts); },
  setAppearance(dark) { if (view !== undefined) applyAppearance(view, dark); },
  setDisplayModes(modes) { if (view !== undefined) applyDisplayModes(view, modes); },
  exportHTML(mode?: string) {
    if (view === undefined) throw new Error('编辑器尚未就绪。');
    return documentHTML(view, mode === 'pdf' ? 'pdf' : 'html');
  },
  snapshot() {
    if (view === undefined) throw new Error('编辑器尚未就绪。');
    if (isComposing(view)) throw new Error('请先确认输入法候选文字，再保存或关闭。');
    return { text: source.read(view.state), revision };
  },
  command(name) {
    if (view === undefined || isComposing(view)) return;
    const input = document.activeElement;
    syncTableSelection(view);
    if (input instanceof HTMLInputElement && ['undo', 'redo', 'selectAll'].includes(name)
      && (name === 'selectAll' || !input.matches('.cm-inkpot-table-input'))) {
      if (name === 'selectAll') input.select(); else document.execCommand(name);
      return;
    }
    if (formatCommands[name] !== undefined && (!view.contentDOM.contains(input)
      || (input?.matches('.cm-inkpot-table-input') === true && !['bold', 'italic', 'strikethrough', 'inlineCode', 'link'].includes(name)))) return;
    commands[name]?.(view);
  },
};

window.webkit.messageHandlers.document.postMessage({ ready: true });
