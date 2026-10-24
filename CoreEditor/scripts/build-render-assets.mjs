import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';

// MVP 的公式、图表与代码语言资源：复用已有 KaTeX、Mermaid 与 legacy-modes，打包到 mvp/dist/math，
// 由应用经 inkpot-asset:// 按需加载，不进入单文件 index.html，避免拖慢启动。
const require = createRequire(import.meta.url);
// 与 mvp/code-languages.ts 的 file 字段保持一致；语言文件不依赖 CodeMirror 运行时，由编辑器包装为 StreamLanguage。
const legacyModes = dirname(require.resolve('@codemirror/legacy-modes/package.json'));
const languages = ['javascript', 'python', 'xml', 'css', 'shell', 'sql', 'yaml', 'toml', 'swift', 'go', 'rust', 'clike', 'ruby', 'lua', 'diff', 'dockerfile'];
const output = resolve('mvp/dist/math');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await build({
  entryPoints: {
    katex: require.resolve('katex/dist/katex.mjs'),
    mermaid: require.resolve('mermaid'),
    ...Object.fromEntries(languages.map(name => [`lang-${name}`, resolve(legacyModes, 'mode', `${name}.js`)])),
  },
  splitting: true,
  outdir: output,
  bundle: true,
  format: 'esm',
  outExtension: { '.js': '.mjs' },
  target: 'safari18',
  minify: true,
  legalComments: 'eof',
});
const katex = dirname(require.resolve('katex/package.json'));
await cp(resolve(katex, 'dist/katex.min.css'), resolve(output, 'katex.min.css'));
await cp(resolve(katex, 'dist/fonts'), resolve(output, 'fonts'), { recursive: true });
await cp(resolve(katex, 'LICENSE'), resolve(output, 'KaTeX-LICENSE.txt'));
await cp(resolve(dirname(require.resolve('mermaid/package.json')), 'LICENSE'), resolve(output, 'Mermaid-LICENSE.txt'));
await cp(resolve(legacyModes, 'LICENSE'), resolve(output, 'CodeMirror-legacy-modes-LICENSE.txt'));
