import { StateEffect, StateField } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

const setSourceMode = StateEffect.define<boolean>();
export const sourceMode = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.find(effect => effect.is(setSourceMode))?.value ?? value,
});

export function isComposing(view: EditorView) {
  return view.compositionStarted || view.dom.querySelector('[data-table-composing]') !== null;
}

export function toggleSourceMode(view: EditorView) {
  if (isComposing(view)) return false;
  view.dispatch({ effects: setSourceMode.of(!view.state.field(sourceMode)) });
  return true;
}
