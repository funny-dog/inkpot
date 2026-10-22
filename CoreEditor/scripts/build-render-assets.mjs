import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';

const require = createRequire(import.meta.url);
const output = resolve('public/EditorAssets');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await build({
  entryPoints: { katex: require.resolve('katex/dist/katex.mjs'), mermaid: require.resolve('mermaid') },
  outdir: output,
  bundle: true,
  splitting: true,
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
