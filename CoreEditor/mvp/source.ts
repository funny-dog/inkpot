import { EditorState, StateEffect, StateField } from '@codemirror/state';
import { invertedEffects } from '@codemirror/commands';

const restoreEnding = StateEffect.define<{ position: number; ending: string }>({
  map: (value, changes) => ({ ...value, position: changes.mapPos(value.position, 1) }),
});

// CodeMirror 使用 LF 定位；单独保存行尾，避免编辑一处就重写整份文件。
// 只记录与占多数的行尾（base）不同的换行，行尾统一的文件不需要任何记录，每次编辑不必重建全部位置。
// 新输入的换行沿用文件首个行尾（preferred）；两者不同时，新换行也作为例外记录。
export function sourceDocument(text: string) {
  const exceptions = new Map<number, string>();
  const preferred = /\r\n|\r|\n/.exec(text)?.[0] ?? '\n';
  const counts = new Map<string, number>();
  for (const ending of text.match(/\r\n|\r|\n/g) ?? []) counts.set(ending, (counts.get(ending) ?? 0) + 1);
  let base = preferred;
  for (const [ending, count] of counts) if (count > (counts.get(base) ?? 0)) base = ending;
  let removed = 0;
  const normalized = text.replace(/\r\n|\r|\n/g, (ending, offset: number) => {
    if (ending !== base) exceptions.set(offset - removed, ending);
    removed += ending.length - 1;
    return '\n';
  });

  const field = StateField.define<Map<number, string>>({
    create: () => exceptions,
    update(value, transaction) {
      if (!transaction.docChanged) return value;
      let next = value;
      // 仅在确有修改时复制，避免共享给旧状态的记录被改写。
      const writable = () => next === value ? (next = new Map(value)) : next;
      if (value.size > 0) {
        next = new Map<number, string>();
        const deletedRanges: { from: number; to: number }[] = [];
        transaction.changes.iterChangedRanges((from, to) => deletedRanges.push({ from, to }));
        for (const [position, ending] of value) {
          if (!deletedRanges.some(({ from, to }) => from <= position && position < to)) {
            next.set(transaction.changes.mapPos(position, 1), ending);
          }
        }
      }
      if (preferred !== base) {
        transaction.changes.iterChanges((_from, _to, start, _end, inserted) => {
          let offset = start;
          for (let line = 1; line < inserted.lines; line++) {
            offset += inserted.line(line).length;
            writable().set(offset++, preferred);
          }
        });
      }
      for (const effect of transaction.effects) {
        if (!effect.is(restoreEnding)) continue;
        if (effect.value.ending === base) writable().delete(effect.value.position);
        else writable().set(effect.value.position, effect.value.ending);
      }
      return next;
    },
  });

  return {
    doc: normalized,
    extensions: [field, invertedEffects.of(transaction => {
      // 撤销或重做时被删除的换行按 preferred 重新插入，只需为行尾不同的换行补记恢复效果。
      const effects: StateEffect<{ position: number; ending: string }>[] = [];
      const { doc } = transaction.startState;
      const current = transaction.startState.field(field);
      transaction.changes.iterChangedRanges((from, to) => {
        if (from === to) return;
        const deleted = doc.sliceString(from, to);
        for (let index = deleted.indexOf('\n'); index >= 0; index = deleted.indexOf('\n', index + 1)) {
          const ending = current.get(from + index) ?? base;
          if (ending !== preferred) effects.push(restoreEnding.of({ position: from + index, ending }));
        }
      });
      return effects;
    })],
    read(state: EditorState): string {
      const current = state.field(field);
      return state.doc.toString().replace(/\n/g, (_newline, position: number) => current.get(position) ?? base);
    },
  };
}
