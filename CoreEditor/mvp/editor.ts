import { EditorState } from '@codemirror/state';
import { Command, EditorView, keymap } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, selectAll, undo, undoDepth } from '@codemirror/commands';
import { sourceDocument } from './source';
import { writingExtensions } from './writing';
import { formatCommands } from './format';
import { searchCommands } from './search';

declare const window: {
  kernmarkMVP: {
    open: (text: string) => void;
    snapshot: () => { text: string; revision: number };
    command: (name: string) => void;
  };
  webkit: { messageHandlers: { document: { postMessage: (message: unknown) => void } } };
};

let view: EditorView | undefined;
let source = sourceDocument('');
let revision = 0;
const commands: Readonly<Partial<Record<string, Command>>> = { undo, redo, selectAll, ...formatCommands, ...searchCommands };

function publish(changed: boolean) {
  if (view === undefined) return;
  window.webkit.messageHandlers.document.postMessage({
    changed,
    revision,
    canUndo: undoDepth(view.state) > 0,
    canRedo: redoDepth(view.state) > 0,
    searchInputFocused: document.activeElement instanceof HTMLInputElement,
    editorFocused: view.contentDOM.contains(document.activeElement),
  });
}

document.addEventListener('focusin', () => queueMicrotask(() => publish(false)));
document.addEventListener('focusout', () => queueMicrotask(() => publish(false)));

window.kernmarkMVP = {
  open(text) {
    view?.destroy();
    source = sourceDocument(text);
    revision = 0;
    view = new EditorView({
      parent: document.body,
      state: EditorState.create({
        doc: source.doc,
        extensions: [
          ...source.extensions,
          ...writingExtensions,
          history(),
          keymap.of([...historyKeymap, ...defaultKeymap]),
          EditorView.lineWrapping,
          EditorView.contentAttributes.of({ 'aria-label': 'Markdown 文本编辑器', spellcheck: 'false' }),
          EditorView.updateListener.of(update => {
            if (update.docChanged) {
              revision++;
              publish(true);
            }
          }),
          EditorView.theme({
            '&': { height: '100%' },
            '.cm-scroller': { overflow: 'auto', fontFamily: 'Menlo, monospace', fontSize: '15px', lineHeight: '1.6' },
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
  },
  snapshot() {
    if (view === undefined) throw new Error('编辑器尚未就绪。');
    if (view.composing) throw new Error('请先确认输入法候选文字，再保存或关闭。');
    return { text: source.read(view.state), revision };
  },
  command(name) {
    if (view === undefined || view.composing) return;
    const input = document.activeElement;
    if (input instanceof HTMLInputElement && ['undo', 'redo', 'selectAll'].includes(name)) {
      if (name === 'selectAll') input.select(); else document.execCommand(name);
      return;
    }
    if (formatCommands[name] !== undefined && !view.contentDOM.contains(input)) return;
    commands[name]?.(view);
  },
};

window.webkit.messageHandlers.document.postMessage({ ready: true });
