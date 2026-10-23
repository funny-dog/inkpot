import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { invertedEffects } from '@codemirror/commands';

const restoreEnding = StateEffect.define<{ position: number; ending: string }>({
  map: (value, changes) => ({ ...value, position: changes.mapPos(value.position, 1) }),
});

// CodeMirror 使用 LF 定位；单独保存行尾，避免编辑一处就重写整份文件。
export function sourceDocument(text: string) {
  const endings = new Map<number, string>();
  const preferred = /\r\n|\r|\n/.exec(text)?.[0] ?? '\n';
  let removed = 0;
  const normalized = text.replace(/\r\n|\r|\n/g, (ending, offset: number) => {
    endings.set(offset - removed, ending);
    removed += ending.length - 1;
    return '\n';
  });

  const field = StateField.define<Map<number, string>>({
    create: () => endings,
    update(value, transaction) {
      if (!transaction.docChanged) return value;
      const next = new Map<number, string>();
      const deletedRanges: { from: number; to: number }[] = [];
      transaction.changes.iterChangedRanges((from, to) => deletedRanges.push({ from, to }));
      for (const [position, ending] of value) {
        if (!deletedRanges.some(({ from, to }) => from <= position && position < to)) {
          next.set(transaction.changes.mapPos(position, 1), ending);
        }
      }
      transaction.changes.iterChanges((_from, _to, start, _end, inserted) => {
        let offset = start;
        for (let line = 1; line < inserted.lines; line++) {
          offset += inserted.line(line).length;
          next.set(offset++, preferred);
        }
      });
      for (const effect of transaction.effects) {
        if (effect.is(restoreEnding)) next.set(effect.value.position, effect.value.ending);
      }
      return next;
    },
  });

  return {
    doc: normalized,
    extensions: [field, invertedEffects.of(transaction => {
      const effects: StateEffect<{ position: number; ending: string }>[] = [];
      transaction.changes.iterChangedRanges((from, to) => {
        for (const [position, ending] of transaction.startState.field(field)) {
          if (from <= position && position < to) effects.push(restoreEnding.of({ position, ending }));
        }
      });
      return effects;
    })],
    read(state: EditorState): string {
      const current = state.field(field);
      return state.doc.toString().replace(/\n/g, (_newline, position: number) => current.get(position) ?? preferred);
    },
  };
}
