import { describe, expect, test } from '@jest/globals';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { sourceDocument } from '../editor/source';
import { writingExtensions } from '../editor/writing';
import { liveEditing } from '../editor/live';
import { selectionTouchesAny, topBlocks } from '../editor/blocks';

const text = [
  '# 标题', '', '[toc]', '', '正文段落', '',
  '$$', 'E = mc^2', '$$', '',
  '| A | B |', '| --- | --- |', '| x | y |', '',
  '```mermaid', 'graph TD', 'A-->B', '```', '',
  '- 列表里的段落', '  ', '  $$', '  x', '  $$', '',
  '结尾段落',
].join('\n');

function state(selection = 0) {
  const source = sourceDocument(text);
  return EditorState.create({ doc: source.doc, selection: { anchor: selection }, extensions: [...source.extensions, ...writingExtensions, ...liveEditing] });
}

// 只取 StateField 提供的块级装饰集合；视图插件提供的是函数。
function blockSets(current: EditorState) {
  return current.facet(EditorView.decorations).filter(value => typeof value !== 'function');
}

describe('Inkpot 顶层块索引', () => {
  test('只收集文档顶层的公式、目录、表格和图表，容器内部的块不计入', () => {
    const blocks = topBlocks(state());
    const slice = (node: { from: number; to: number }) => text.slice(node.from, node.to);
    expect(blocks.math.map(slice)).toEqual(['$$\nE = mc^2\n$$']);
    expect(blocks.toc.map(slice)).toEqual(['[toc]']);
    expect(blocks.table.map(slice)).toEqual(['| A | B |\n| --- | --- |\n| x | y |']);
    expect(blocks.mermaid.map(slice)).toEqual(['```mermaid\ngraph TD\nA-->B\n```']);
    // 同一棵语法树重复读取时复用结果。
    const current = state();
    expect(topBlocks(current)).toBe(topBlocks(current));
  });

  test('选区判定与 selectionTouches 口径一致：光标须在块内部，选区须重叠', () => {
    const current = state();
    const nodes = topBlocks(current).math;
    const { from, to } = nodes[0];
    const touches = (selection: EditorSelection) => selectionTouchesAny(nodes, selection);
    expect(touches(EditorSelection.single(from))).toBe(false);
    expect(touches(EditorSelection.single(from + 1))).toBe(true);
    expect(touches(EditorSelection.single(to))).toBe(false);
    expect(touches(EditorSelection.single(0, from))).toBe(false);
    expect(touches(EditorSelection.single(0, from + 1))).toBe(true);
    expect(touches(EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(to - 1)]))).toBe(true);
    expect(selectionTouchesAny([], EditorSelection.single(3))).toBe(false);
  });

  test('光标在块外移动时块级装饰保持原对象，进入或离开块时才重建', () => {
    const start = state(1);
    const before = blockSets(start);
    expect(before.length).toBeGreaterThanOrEqual(4);
    const moved = start.update({ selection: { anchor: text.indexOf('正文') + 1 } }).state;
    expect(blockSets(moved)).toEqual(before);
    blockSets(moved).forEach((set, index) => expect(set).toBe(before[index]));

    const inside = moved.update({ selection: { anchor: text.indexOf('E = mc') } }).state;
    expect(blockSets(inside).some((set, index) => set !== before[index])).toBe(true);
    const left = inside.update({ selection: { anchor: text.indexOf('结尾') } }).state;
    expect(blockSets(left).some((set, index) => set !== blockSets(inside)[index])).toBe(true);
  });
});
