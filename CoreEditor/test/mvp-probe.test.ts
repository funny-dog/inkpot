import { describe, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { history } from '@codemirror/commands';
import { sourceDocument } from '../mvp/source';
import { writingExtensions } from '../mvp/writing';
import { liveEditing } from '../mvp/live';

describe('探针', () => {
  test('删除线 DOM', () => {
    const source = sourceDocument('**加粗** ~~删除~~ ==高亮==\n');
    const view = new EditorView({ parent: document.body, state: EditorState.create({ doc: source.doc,
      extensions: [...source.extensions, ...writingExtensions, ...liveEditing, history()] }) });
    const spans = [...view.contentDOM.querySelectorAll('span')].map(e => `${JSON.stringify(e.className)}「${e.textContent}」`);
    console.log(spans.join('\n'));
    view.destroy();
  });
});
