import { describe, expect, test } from '@jest/globals';
import { EditorState } from '@codemirror/state';
import { sourceDocument } from '../mvp/source';
import { documentStats } from '../mvp/stats';

function stats(text: string) {
  return documentStats(EditorState.create({ doc: sourceDocument(text).doc }));
}

describe('MVP 字数统计', () => {
  test('纯中文按字计数', () => {
    expect(stats('你好世界').words).toBe(4);
    expect(stats('你好世界').characters).toBe(4);
    expect(stats('你好世界').lines).toBe(1);
  });

  test('英文按词计数，数字串算一词', () => {
    expect(stats('hello world 2026').words).toBe(3);
    expect(stats("don't stop").words).toBe(2);
  });

  test('中英混合：中日韩逐字加西文按词', () => {
    expect(stats('你好 world 2026').words).toBe(4);
    expect(stats('カタカナと日本語').words).toBe(8);
  });

  test('空白与标点不计数，markdown 标记计入字符', () => {
    expect(stats('# 标题 **加粗**').words).toBe(4);
    expect(stats('# 标题 **加粗**').characters).toBe(11);
  });

  test('空文档与多行', () => {
    expect(stats('')).toEqual({ words: 0, characters: 0, lines: 1 });
    expect(stats('第一行\n\n第三行').lines).toBe(3);
    expect(stats('第一行\n\n第三行').characters).toBe(6);
  });

  test('十万字符在阈值内完成', () => {
    const text = '中文与 english 混合的正文。\n'.repeat(5000);
    const started = Date.now();
    const result = stats(text);
    expect(result.characters).toBe(90000);
    expect(Date.now() - started).toBeLessThan(200);
  });
});
