import { Compartment, EditorState, Line } from '@codemirror/state';
import { indentUnit } from '@codemirror/language';
import { EditorView, KeyBinding } from '@codemirror/view';
import { isComposing } from './mode';

// 缩进宽度来自设置（2 或 4 个空格），代码块内的 Tab 缩进同样读取 indentUnit。
export const indentCompartment = new Compartment();
export const indentWidth = (width: number) => indentUnit.of(' '.repeat(width === 4 ? 4 : 2));

const listItem = /^([ \t]*)([-+*]|\d{1,9}[.)])([ \t]+|$)/;

function leading(text: string) { return /^[ \t]*/.exec(text)?.[0].length ?? 0; }

function selectedLines(state: EditorState) {
  const lines = new Map<number, Line>();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number;
    const last = state.doc.lineAt(range.empty || range.to === range.from ? range.to : range.to - 1).number;
    for (let number = first; number <= last; number++) lines.set(number, state.doc.line(number));
  }
  return [...lines.values()];
}

/// 列表子项要缩进到上一同级项的正文起点，CommonMark 才会识别为嵌套；有序列表“1. ”需要 3 格。
function nestWidth(state: EditorState, line: Line, unit: number) {
  const own = leading(line.text);
  for (let number = line.number - 1; number >= 1; number--) {
    const text = state.doc.line(number).text;
    if (!/\S/.test(text)) continue;
    const match = listItem.exec(text);
    if (match === null || match[1].length < own) return unit;
    if (match[1].length === own) return Math.max(unit, match[2].length + Math.max(1, Math.min(match[3].length, 4)));
  }
  return unit;
}

/// 反缩进回到最近一个缩进更浅的父列表项，避免有序列表退出后残留半格空白。
function parentIndent(state: EditorState, line: Line, unit: number) {
  const own = leading(line.text);
  for (let number = line.number - 1; number >= 1; number--) {
    const text = state.doc.line(number).text;
    if (!/\S/.test(text)) continue;
    const match = listItem.exec(text);
    if (match === null) break;
    if (match[1].length < own) return match[1].length;
  }
  return Math.max(0, own - unit);
}

function editable(view: EditorView) {
  return !view.state.readOnly && view.state.facet(EditorView.editable);
}

export function indentLines(view: EditorView) {
  if (isComposing(view)) return true;
  if (!editable(view)) return false;
  const { state } = view;
  const unit = state.facet(indentUnit).length;
  const lines = selectedLines(state);
  const lineLevel = state.selection.ranges.some(range => !range.empty) || lines.every(line => listItem.test(line.text));
  if (!lineLevel) {
    view.dispatch(state.update(state.replaceSelection(state.facet(indentUnit)), { userEvent: 'input.indent', scrollIntoView: true }));
    return true;
  }
  const changes = lines.filter(line => /\S/.test(line.text)).map(line => ({
    from: line.from, insert: ' '.repeat(listItem.test(line.text) ? nestWidth(state, line, unit) : unit),
  }));
  if (changes.length > 0) view.dispatch({ changes, userEvent: 'input.indent', scrollIntoView: true });
  return true;
}

export function outdentLines(view: EditorView) {
  if (isComposing(view)) return true;
  if (!editable(view)) return false;
  const { state } = view;
  const unit = state.facet(indentUnit).length;
  const changes = selectedLines(state).flatMap(line => {
    const own = leading(line.text);
    if (own === 0) return [];
    const target = listItem.test(line.text) ? parentIndent(state, line, unit) : Math.max(0, own - unit);
    return [{ from: line.from + target, to: line.from + own }];
  });
  if (changes.length > 0) view.dispatch({ changes, userEvent: 'delete.dedent', scrollIntoView: true });
  return true;
}

// 放在代码块与表格的 Tab 绑定之后，只处理它们没接手的位置。
export const indentBindings: KeyBinding[] = [{ key: 'Tab', run: indentLines, shift: outdentLines }];
