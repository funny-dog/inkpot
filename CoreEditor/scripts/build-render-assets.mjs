import { build } from 'esbuild';
import { cp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';

// Inkpot 的公式、图表与代码语言资源：复用已有 KaTeX、Mermaid 与 legacy-modes，打包到 editor/dist/math，
// 由应用经 inkpot-asset:// 按需加载，不进入单文件 index.html，避免拖慢启动。
const require = createRequire(import.meta.url);
// 与 editor/code-languages.ts 的 file 字段保持一致；语言文件不依赖 CodeMirror 运行时，由编辑器包装为 StreamLanguage。
const legacyModes = dirname(require.resolve('@codemirror/legacy-modes/package.json'));
const katexEntry = require.resolve('katex/dist/katex.mjs');
const languages = ['javascript', 'python', 'xml', 'css', 'shell', 'sql', 'yaml', 'toml', 'swift', 'go', 'rust', 'clike', 'ruby', 'lua', 'diff', 'dockerfile'];
const output = resolve('editor/dist/math');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await build({
  entryPoints: {
    katex: katexEntry,
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
  plugins: [
    {
      name: 'inkpot-trim-render-assets',
      setup(pluginBuild) {
        // Mermaid 已在运行时通过 secure 锁死 layout: 'dagre'，跳过永不执行的 1.4 MB ELK 布局引擎分块。
        pluginBuild.onResolve({ filter: /(?:^|\/)elk-[^/]+\.mjs$/ }, () => ({
          path: 'inkpot-stub-elk',
          namespace: 'inkpot-stub',
        }));
        pluginBuild.onLoad({ filter: /.*/, namespace: 'inkpot-stub' }, () => ({
          contents: 'export default {}; export const diagram = {};',
          loader: 'js',
        }));
        // 统一 Mermaid 嵌套依赖的 KaTeX 到顶层单份，避免双版本重复打包。
        pluginBuild.onResolve({ filter: /^katex(?:\/dist\/katex\.mjs)?$/ }, () => ({
          path: katexEntry,
        }));
      },
    },
  ],
});
const katex = dirname(require.resolve('katex/package.json'));
// 目标运行环境（Safari 18+ / Chromium 120+）全部原生支持 woff2，剔除冗余的 .woff/.ttf 回退声明与字体文件。
const katexCSS = (await readFile(resolve(katex, 'dist/katex.min.css'), 'utf8'))
  .replace(/,url\(fonts\/[^)]+\.(?:woff|ttf)\) format\("(?:woff|truetype)"\)/g, '');
await writeFile(resolve(output, 'katex.min.css'), katexCSS, 'utf8');
const fontsSrc = resolve(katex, 'dist/fonts');
const fontsDst = resolve(output, 'fonts');
await mkdir(fontsDst, { recursive: true });
for (const name of await readdir(fontsSrc)) {
  if (name.endsWith('.woff2')) {
    await cp(resolve(fontsSrc, name), resolve(fontsDst, name));
  }
}
await cp(resolve(katex, 'LICENSE'), resolve(output, 'KaTeX-LICENSE.txt'));
await cp(resolve(dirname(require.resolve('mermaid/package.json')), 'LICENSE'), resolve(output, 'Mermaid-LICENSE.txt'));
await cp(resolve(legacyModes, 'LICENSE'), resolve(output, 'CodeMirror-legacy-modes-LICENSE.txt'));
