import { ensureSyntaxTree } from '@codemirror/language';
import { EditorState } from '@codemirror/state';
import { EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';
import { Tree } from '@lezer/common';

export interface Heading {
  id: number;
  from: number;
  to: number;
  level: number;
  title: string;
}

export function headings(state: EditorState, tree: Tree): Omit<Heading, 'id'>[] {
  const result: Omit<Heading, 'id'>[] = [];
  tree.iterate({
    enter(node) {
      if (!/^(ATX|Setext)Heading[1-6]$/.test(node.name)) return;
      const removed: { from: number; to: number }[] = [];
      node.node.toTree().iterate({
        enter(child) {
          const parent = child.node.parent?.name;
          if (['HeaderMark', 'EmphasisMark', 'CodeMark', 'LinkMark'].includes(child.name)
            || (['URL', 'LinkTitle', 'LinkLabel'].includes(child.name) && ['Link', 'Image'].includes(parent ?? ''))) {
            removed.push({ from: node.from + child.from, to: node.from + child.to });
            return false;
          }
        },
      });
      let title = '';
      let pos = node.from;
      for (const range of removed) {
        title += state.sliceDoc(pos, range.from);
        pos = range.to;
      }
      title += state.sliceDoc(pos, node.to);
      result.push({ from: node.from, to: node.to, level: Number(node.name.at(-1)), title: title.trim().replace(/\s+/g, ' ') || '（空标题）' });
      return false;
    },
  });
  return result;
}

export function activeHeading(items: readonly Heading[], position: number): number | null {
  let active: number | null = null;
  for (const item of items) {
    if (item.from > position) break;
    active = item.id;
  }
  return active;
}

export function documentOutline(publish: (items: Heading[] | undefined, active: number | null) => void) {
  const plugin = ViewPlugin.fromClass(class {
    items: Heading[] = [];
    private nextID = 0;
    private position = 0;
    private dirty = true;
    private timer: ReturnType<typeof setTimeout> | undefined;
    private active: number | null | undefined;

    constructor(private readonly view: EditorView) { this.schedule(); }

    update(update: ViewUpdate) {
      if (update.docChanged) {
        // 用映射后的范围识别同一个标题，避免前文编辑或重命名重置折叠状态。
        this.items = this.items.map(item => ({ ...item,
          from: update.changes.mapPos(item.from, 1), to: update.changes.mapPos(item.to, -1),
        }));
        this.position = update.changes.mapPos(this.position);
        this.dirty = true;
        this.schedule();
      } else if (update.geometryChanged || update.viewportChanged) {
        this.measure();
      }
    }

    private schedule() {
      if (this.timer !== undefined) clearTimeout(this.timer);
      this.timer = setTimeout(() => { this.timer = undefined; this.refresh(); }, 100);
    }

    refresh(): boolean {
      if (this.timer !== undefined) clearTimeout(this.timer);
      this.timer = undefined;
      if (this.view.composing) { this.schedule(); return false; }
      // 分片补齐可视区之外的解析，每次只占用短时间；不在输入事件中扫描全文。
      const tree = ensureSyntaxTree(this.view.state, this.view.state.doc.length, 10);
      if (tree === null) { this.schedule(); return false; }
      const previous = this.items;
      let previousIndex = 0;
      this.items = headings(this.view.state, tree).map(item => {
        while (previousIndex < previous.length && previous[previousIndex].to <= item.from) previousIndex++;
        const old = previous.at(previousIndex);
        const matches = old !== undefined && old.from < item.to && old.to > item.from;
        const id = matches ? old.id : this.nextID++;
        if (matches) previousIndex++;
        return { ...item, id };
      });
      this.dirty = false;
      this.active = activeHeading(this.items, this.position);
      publish(this.items, this.active);
      this.measure();
      return true;
    }

    measure() {
      if (this.dirty) return;
      this.view.requestMeasure({
        key: this,
        read: view => {
          const top = view.scrollDOM.getBoundingClientRect().top + 8;
          const position = view.state.doc.lineAt(view.lineBlockAtHeight(top - view.documentTop).from).to;
          return { active: activeHeading(this.items, position), position };
        },
        write: ({ active, position }) => {
          if (this.dirty) return;
          this.position = position;
          if (active !== this.active) {
            this.active = active;
            publish(undefined, active);
          }
        },
      });
    }

    navigate(id: number) {
      if (this.view.composing || (this.dirty && !this.refresh())) return;
      const heading = this.items.find(item => item.id === id);
      if (heading === undefined) return;
      const node = ensureSyntaxTree(this.view.state, heading.to)?.resolveInner(heading.from, 1);
      const mark = node?.name === 'HeaderMark' ? node : node?.getChild('HeaderMark');
      const start = mark?.from === heading.from ? mark.to : heading.from;
      const spaces = /^\s*/.exec(this.view.state.sliceDoc(start, this.view.state.doc.lineAt(start).to))?.[0].length ?? 0;
      this.view.dispatch({
        selection: { anchor: start + spaces },
        effects: EditorView.scrollIntoView(heading.from, { y: 'start', yMargin: 8 }),
      });
      this.view.focus();
    }

    destroy() { if (this.timer !== undefined) clearTimeout(this.timer); }
  }, {
    eventHandlers: { scroll() { this.measure(); } },
  });
  return { extension: plugin, navigate: (view: EditorView, id: number) => view.plugin(plugin)?.navigate(id) };
}
