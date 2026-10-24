import { EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';

// 空文档底部的常用快捷键提示：只在文档为空时显示，输入第一个字即隐藏；挂在编辑器根节点而非内容区，不进入导出与打印。
const shortcuts: [string, string][] = [['⌘O', '打开文件'], ['⌥⌘O', '打开文件夹'], ['⇧⌘M', '切换源码模式'], ['⌘,', '设置']];

const welcomePlugin = ViewPlugin.fromClass(class {
  private readonly dom: HTMLElement;

  constructor(view: EditorView) {
    this.dom = document.createElement('div');
    this.dom.className = 'cm-inkpot-welcome';
    this.dom.setAttribute('role', 'note');
    this.dom.setAttribute('aria-label', '常用快捷键');
    const list = document.createElement('dl');
    for (const [key, label] of shortcuts) {
      const item = document.createElement('div');
      const term = document.createElement('dt');
      const detail = document.createElement('dd');
      term.textContent = key;
      detail.textContent = label;
      item.append(term, detail);
      list.append(item);
    }
    this.dom.append(list);
    view.dom.append(this.dom);
    this.sync(view);
  }

  update(update: ViewUpdate) {
    if (update.docChanged) this.sync(update.view);
  }

  private sync(view: EditorView) {
    this.dom.hidden = view.state.doc.length > 0;
  }

  destroy() { this.dom.remove(); }
});

const welcomeTheme = EditorView.theme({
  '.cm-placeholder': { color: '#a1a1a6' },
  '.cm-inkpot-welcome': { position: 'absolute', left: '48px', right: '48px', bottom: '56px', display: 'flex', justifyContent: 'center', pointerEvents: 'none', font: '12px -apple-system, "PingFang SC", system-ui, sans-serif' },
  '.cm-inkpot-welcome[hidden]': { display: 'none' },
  '.cm-inkpot-welcome dl': { margin: '0', width: '600px', maxWidth: '100%', display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: '12px' },
  '.cm-inkpot-welcome dl > div': { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '6px' },
  '.cm-inkpot-welcome dt': { font: '500 12px "SF Mono", Menlo, monospace', color: '#3a3a3c', padding: '3px 8px', borderRadius: '5px', backgroundColor: '#f1f1f4' },
  '.cm-inkpot-welcome dd': { margin: '0', color: '#6e6e73', whiteSpace: 'nowrap' },
});

export const welcomeHints = [welcomePlugin, welcomeTheme];
