import { EditorState } from '@codemirror/state';
import { Command, EditorView, keymap } from '@codemirror/view';
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
import { documentHTML } from './export';
import { applyAppearance, appearanceExtensionsFor } from './theme';
import { isComposing } from './mode';
import { linkAt, linkNavigation } from './basic';
import { applyFonts, EditorFonts } from './fonts';
import { richPaste } from './paste';

declare const window: {
  inkpotMVP: {
    open: (text: string, generation?: number, dark?: boolean) => void;
    navigateHeading: (id: number) => void;
    navigateFragment: (fragment: string) => void;
    insertImage: (path: string) => void;
    refreshImages: () => void;
    snapshot: () => { text: string; revision: number };
    command: (name: string) => void;
    setAppearance: (dark: boolean) => void;
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
    searchInputFocused: document.activeElement instanceof HTMLInputElement && !document.activeElement.matches('.cm-mvp-table-input'),
    tableCellFocused: document.activeElement?.matches('.cm-mvp-table-input') === true,
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

window.inkpotMVP = {
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
          EditorView.contentAttributes.of({ 'aria-label': 'Markdown 文本编辑器', spellcheck: 'false' }),
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
            '.cm-scroller': { overflow: 'auto', fontFamily: 'var(--inkpot-code-font, Menlo, monospace)', fontSize: 'var(--inkpot-code-size, 15px)', lineHeight: '1.6' },
            '.cm-content': { padding: '24px', minHeight: '100%' },
            '&.cm-focused': { outline: 'none' },
            '.cm-panels': { backgroundColor: '#f7f7f7', color: '#202020' },
            '.cm-mvp-search': { padding: '8px', font: '13px system-ui' },
            '.cm-mvp-search > div': { display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' },
            '.cm-mvp-search > div + div': { marginTop: '6px' },
            '.cm-mvp-search input': { font: 'inherit', flex: '1 1 140px', minWidth: '0', maxWidth: '360px', padding: '4px' },
            '.cm-mvp-search button': { font: 'inherit', padding: '4px 8px' },
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
  insertImage(path) {
    if (view === undefined || isComposing(view) || view.state.readOnly) throw new Error('请先结束输入或等待编辑器就绪，再插入图片。');
    view.dispatch(view.state.update({ ...view.state.replaceSelection(`![图片](${path})`), annotations: isolateHistory.of('full'), userEvent: 'input.image', scrollIntoView: true }));
    view.focus();
  },
  refreshImages() { view?.dispatch({ effects: refreshImages.of(null) }); },
  setFonts(fonts) { if (view !== undefined) applyFonts(view, fonts); },
  setAppearance(dark) { if (view !== undefined) applyAppearance(view, dark); },
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
      && (name === 'selectAll' || !input.matches('.cm-mvp-table-input'))) {
      if (name === 'selectAll') input.select(); else document.execCommand(name);
      return;
    }
    if (formatCommands[name] !== undefined && (!view.contentDOM.contains(input)
      || (input?.matches('.cm-mvp-table-input') === true && !['bold', 'italic'].includes(name)))) return;
    commands[name]?.(view);
  },
};

window.webkit.messageHandlers.document.postMessage({ ready: true });
