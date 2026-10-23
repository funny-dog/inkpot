const assetBase = typeof window.webkit?.messageHandlers === 'object'
  ? 'inkpot-asset://editor/' : '/EditorAssets/';

let katex: Promise<typeof import('katex')> | undefined;
let mermaid: Promise<typeof import('mermaid').default> | undefined;

export function loadKatex() {
  return katex ??= importKatex();
}

async function importKatex() {
  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = `${assetBase}katex.min.css`;
  document.head.appendChild(css);
  const module = await import(/* @vite-ignore */ `${assetBase}katex.mjs`) as { default: typeof import('katex') };
  return module.default;
}

export function loadMermaid() {
  return mermaid ??= importMermaid();
}

async function importMermaid() {
  const module = await import(/* @vite-ignore */ `${assetBase}mermaid.mjs`) as typeof import('mermaid');
  module.default.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true });
  return module.default;
}
