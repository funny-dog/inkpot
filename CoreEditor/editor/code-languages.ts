import { t } from './localization';
import { RangeSetBuilder, StateEffect } from '@codemirror/state';
import { LanguageDescription, LanguageSupport, ParseContext, StreamLanguage, StreamParser, syntaxTree } from '@codemirror/language';
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from '@codemirror/view';
import { Parser } from '@lezer/common';
import { highlightTree, tagHighlighter, tags } from '@lezer/highlight';
import { isComposing } from './mode';
import type { BlockNest } from './math-parser';
import { assetBase } from './bridge';

// 代码块按语言着色：复用已有 @codemirror/legacy-modes，每个语言文件单独打包到应用包，
// 首次遇到对应围栏时经宿主资源目录加载，未用到的语言不增加启动开销。测试注入替代实现。
type Modes = Record<string, StreamParser<unknown> | undefined>;

let loadModule: (file: string) => Promise<Modes> = file => import(/* @vite-ignore */ `${assetBase}lang-${file}.mjs`) as Promise<Modes>;

export function useLanguageModulesForTests(loader: (file: string) => Promise<Modes>) {
  loadModule = loader;
}

// 代码块内的 Markdown 只着色、不产生结构节点：若嵌入完整 Markdown 语法树，
// 光标处的列表、引用节点会让续写等结构命令误入代码块。
const markdownMode: StreamParser<{ fence: string | null }> = {
  name: 'markdown',
  startState: () => ({ fence: null }),
  copyState: state => ({ ...state }),
  token(stream, state) {
    const eat = (pattern: RegExp) => stream.match(pattern) !== null;
    if (stream.sol()) {
      const fence = /^ {0,3}(`{3,}|~{3,})/.exec(stream.string)?.[1];
      if (fence !== undefined) {
        if (state.fence === null) state.fence = fence;
        else if (fence.startsWith(state.fence[0]) && fence.length >= state.fence.length) state.fence = null;
        stream.skipToEnd();
        return 'meta';
      }
      if (state.fence !== null) { stream.skipToEnd(); return 'string'; }
      if (eat(/^ {0,3}#{1,6}(?=\s|$)/)) { stream.skipToEnd(); return 'heading'; }
      if (eat(/^\s*(?:[-*+]|\d+[.)])(?=\s)/) || eat(/^ {0,3}>/)) return 'keyword';
    }
    if (state.fence !== null) { stream.skipToEnd(); return 'string'; }
    if (eat(/^`[^`]+`/)) return 'string';
    if (eat(/^(\*\*|__)(?=\S).*?\S\1/)) return 'strong';
    if (eat(/^([*_])(?=\S).*?\S\1/)) return 'emphasis';
    if (eat(/^!?\[[^\]]*\]\([^)]*\)/)) return 'link';
    if (!stream.eatWhile(/[^`*_![]/)) stream.next();
    return null;
  },
};

// 名称、别名均按小写比较；file 为打包到应用里的语言文件，mode 为其中导出的语法名。
const definitions: { name: string; alias: string[]; file: string; mode: string }[] = [
  { name: 'JavaScript', alias: ['javascript', 'js', 'jsx', 'mjs', 'cjs', 'node'], file: 'javascript', mode: 'javascript' },
  { name: 'TypeScript', alias: ['typescript', 'ts', 'tsx', 'mts', 'cts'], file: 'javascript', mode: 'typescript' },
  { name: 'JSON', alias: ['json', 'json5', 'jsonc'], file: 'javascript', mode: 'json' },
  { name: 'Python', alias: ['python', 'py', 'python3'], file: 'python', mode: 'python' },
  { name: 'HTML', alias: ['html', 'htm', 'xhtml', 'vue', 'svelte'], file: 'xml', mode: 'html' },
  { name: 'XML', alias: ['xml', 'svg', 'plist'], file: 'xml', mode: 'xml' },
  { name: 'CSS', alias: ['css'], file: 'css', mode: 'css' },
  { name: 'SCSS', alias: ['scss', 'sass'], file: 'css', mode: 'sCSS' },
  { name: 'Less', alias: ['less'], file: 'css', mode: 'less' },
  { name: 'Shell', alias: ['shell', 'sh', 'bash', 'zsh', 'console', 'shellscript'], file: 'shell', mode: 'shell' },
  { name: 'SQL', alias: ['sql'], file: 'sql', mode: 'standardSQL' },
  { name: 'MySQL', alias: ['mysql'], file: 'sql', mode: 'mySQL' },
  { name: 'PostgreSQL', alias: ['postgresql', 'postgres', 'pgsql', 'psql'], file: 'sql', mode: 'pgSQL' },
  { name: 'SQLite', alias: ['sqlite'], file: 'sql', mode: 'sqlite' },
  { name: 'YAML', alias: ['yaml', 'yml'], file: 'yaml', mode: 'yaml' },
  { name: 'TOML', alias: ['toml'], file: 'toml', mode: 'toml' },
  { name: 'Swift', alias: ['swift'], file: 'swift', mode: 'swift' },
  { name: 'Go', alias: ['go', 'golang'], file: 'go', mode: 'go' },
  { name: 'Rust', alias: ['rust', 'rs'], file: 'rust', mode: 'rust' },
  { name: 'C', alias: ['c', 'h'], file: 'clike', mode: 'c' },
  { name: 'C++', alias: ['c++', 'cpp', 'cc', 'cxx', 'hpp', 'hh'], file: 'clike', mode: 'cpp' },
  { name: 'Objective-C', alias: ['objective-c', 'objc', 'objectivec', 'm'], file: 'clike', mode: 'objectiveC' },
  { name: 'Java', alias: ['java'], file: 'clike', mode: 'java' },
  { name: 'Kotlin', alias: ['kotlin', 'kt', 'kts'], file: 'clike', mode: 'kotlin' },
  { name: 'C#', alias: ['c#', 'csharp', 'cs'], file: 'clike', mode: 'csharp' },
  { name: 'Ruby', alias: ['ruby', 'rb'], file: 'ruby', mode: 'ruby' },
  { name: 'Lua', alias: ['lua'], file: 'lua', mode: 'lua' },
  { name: 'Diff', alias: ['diff', 'patch'], file: 'diff', mode: 'diff' },
  { name: 'Dockerfile', alias: ['dockerfile', 'docker'], file: 'dockerfile', mode: 'dockerFile' },
];

/** 打包进应用的语言文件名，供构建脚本与测试核对。 */
export const languageFiles = [...new Set(definitions.map(definition => definition.file))];

const markdownLanguage = StreamLanguage.define(markdownMode);
const descriptions = [
  LanguageDescription.of({ name: 'Markdown', alias: ['markdown', 'md', 'mdx'], support: new LanguageSupport(markdownLanguage) }),
  ...definitions.map(({ name, alias, file, mode }) => LanguageDescription.of({ name, alias, async load() {
    const parser = (await loadModule(file))[mode];
    if (parser === undefined) throw new Error(t('语言文件 {0} 缺少 {1}', file, mode));
    return new LanguageSupport(StreamLanguage.define(parser));
  } })),
];

// 每次增量解析都会为可见范围外的代码块重新查找语言，按名称与别名建索引，避免逐项比较。
const byName = new Map(descriptions.flatMap(description => [description.name.toLowerCase(), ...description.alias].map(name => [name, description] as const)));

/** 围栏信息串首个词对应的语言；未知语言返回 undefined，保持原样。 */
export function codeLanguageFor(info: string) {
  const word = /^\s*([^\s{]+)/.exec(info)?.[1];
  return word === undefined ? undefined : byName.get(word.toLowerCase());
}

const refreshHighlights = StateEffect.define();
const waiting = new Set<LanguageDescription>();
// 加载失败的语言不再重试，避免每次重新解析都请求缺失的资源；代码保持未着色。
const failed = new WeakSet<LanguageDescription>();

async function load(description: LanguageDescription) {
  try {
    await description.load();
    return true;
  } catch {
    failed.add(description);
    return false;
  }
}

function codeParser(info: string): Parser | null {
  const description = codeLanguageFor(info);
  if (description === undefined || failed.has(description)) return null;
  if (description.support !== undefined) return description.support.language.parser;
  // 尚未加载时先跳过这一段，加载完成后由 CodeMirror 重新解析，期间代码保持未着色。
  waiting.add(description);
  return ParseContext.getSkippingParser(load(description));
}

/** 与 @lezer/markdown 的 parseCode 相同的嵌套方式，经 markdownMathWith 并入公式解析的同一次遍历。 */
export const codeNest: BlockNest = (node, input) => {
  if (node.name !== 'FencedCode') return null;
  const info = node.node.getChild('CodeInfo');
  const parser = info === null ? null : codeParser(input.read(info.from, info.to));
  return parser === null ? null : { parser, overlay: inner => inner.name === 'CodeText', bracketed: true };
};

/** 加载文档中已出现、尚未加载的语言，供导出与打印在着色完成后再序列化。 */
export async function loadDocumentLanguages() {
  const pending = [...waiting].filter(description => description.support === undefined && !failed.has(description));
  waiting.clear();
  return (await Promise.all(pending.map(load))).some(Boolean);
}

// 固定类名的着色：编辑器与导出共用同一组类，明暗配色只在主题里各写一份。
const highlighter = tagHighlighter([
  { tag: [tags.keyword, tags.modifier, tags.operatorKeyword], class: 'cm-inkpot-token-keyword' },
  { tag: [tags.string, tags.regexp, tags.character, tags.inserted], class: 'cm-inkpot-token-string' },
  { tag: tags.comment, class: 'cm-inkpot-token-comment' },
  { tag: [tags.number, tags.bool, tags.atom, tags.null], class: 'cm-inkpot-token-number' },
  { tag: [tags.typeName, tags.className, tags.namespace], class: 'cm-inkpot-token-type' },
  { tag: [tags.definition(tags.variableName), tags.function(tags.variableName), tags.function(tags.propertyName)], class: 'cm-inkpot-token-function' },
  { tag: [tags.propertyName, tags.attributeName, tags.labelName], class: 'cm-inkpot-token-property' },
  { tag: [tags.tagName, tags.heading, tags.deleted], class: 'cm-inkpot-token-tag' },
  { tag: [tags.meta, tags.annotation, tags.processingInstruction, tags.special(tags.variableName)], class: 'cm-inkpot-token-meta' },
  { tag: [tags.standard(tags.variableName), tags.self], class: 'cm-inkpot-token-builtin' },
  { tag: [tags.link, tags.url], class: 'cm-inkpot-token-link' },
  { tag: tags.strong, class: 'cm-inkpot-token-strong' },
  { tag: tags.emphasis, class: 'cm-inkpot-token-emphasis' },
]);

const marks = new Map<string, Decoration>();
const mark = (className: string) => marks.get(className) ?? marks.set(className, Decoration.mark({ class: className })).get(className) as Decoration;

function codeHighlights(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);
  for (const { from, to } of view.visibleRanges) {
    // 普通遍历不进入叠加挂载的代码语言树，只在 CodeText 范围内着色，Markdown 本身的标记不受影响。
    tree.iterate({ from, to, enter(node) {
      if (node.name !== 'CodeText') return;
      if (node.node.parent?.name === 'FencedCode') {
        highlightTree(tree, highlighter, (start, end, className) => builder.add(start, end, mark(className)), Math.max(from, node.from), Math.min(to, node.to));
      }
      return false;
    } });
  }
  return builder.finish();
}

export const codeHighlighting = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  private stale = false;
  private refreshTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(view: EditorView) { this.decorations = codeHighlights(view); }

  update(update: ViewUpdate) {
    // 组合输入期间只映射已有着色，不重建候选文字周围的 DOM；结束后统一刷新。
    if (isComposing(update.view)) {
      this.decorations = this.decorations.map(update.changes);
      this.stale ||= update.docChanged || syntaxTree(update.startState) !== syntaxTree(update.state);
    } else if (this.stale || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)
      || update.transactions.some(transaction => transaction.effects.some(effect => effect.is(refreshHighlights)))) {
      this.stale = false;
      this.decorations = codeHighlights(update.view);
    } else if (update.docChanged) {
      this.decorations = this.decorations.map(update.changes);
    }
  }

  compositionEnded(view: EditorView) {
    clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => { if (this.stale && view.dom.isConnected) view.dispatch({ effects: refreshHighlights.of(null) }); }, 80);
  }

  destroy() { clearTimeout(this.refreshTimer); }
}, {
  decorations: value => value.decorations,
  eventHandlers: { compositionend(_event, view) { this.compositionEnded(view); } },
});

// 浅色配色；深色版在 theme.ts，导出沿用编辑器的计算样式。
export const codeHighlightTheme = EditorView.theme({
  '.cm-inkpot-token-keyword': { color: '#a626a4' },
  '.cm-inkpot-token-string': { color: '#50a14f' },
  '.cm-inkpot-token-comment': { color: '#8a8f98', fontStyle: 'italic' },
  '.cm-inkpot-token-number': { color: '#b76b01' },
  '.cm-inkpot-token-type': { color: '#c18401' },
  '.cm-inkpot-token-function': { color: '#4078f2' },
  '.cm-inkpot-token-property': { color: '#986801' },
  '.cm-inkpot-token-tag': { color: '#e45649' },
  '.cm-inkpot-token-meta': { color: '#0184bc' },
  '.cm-inkpot-token-builtin': { color: '#0184bc' },
  '.cm-inkpot-token-link': { color: '#4078f2', textDecoration: 'underline' },
  '.cm-inkpot-token-strong': { fontWeight: 'bold' },
  '.cm-inkpot-token-emphasis': { fontStyle: 'italic' },
});
