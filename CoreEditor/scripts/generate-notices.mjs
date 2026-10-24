// 生成第三方许可致谢文档：MVP/Resources/ThirdPartyNotices.md。
//
// 从 CoreEditor/package.json 的 dependencies 出发，按 Node 模块解析规则（逐级向上
// 查找 node_modules，兼容 scoped 包与嵌套依赖）遍历生产依赖及传递依赖，读取各包
// 的 package.json 与包内许可文件，按许可文本去重后输出 Markdown。
//
// 约束：全程离线（不访问网络），只读 node_modules，不改动依赖与 yarn.lock。
// 再生成：在 CoreEditor/ 下运行 `node .yarn/releases/yarn-4.18.0.cjs notices`。

import { Buffer } from 'node:buffer';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const coreDir = dirname(scriptDir);
const repoDir = dirname(coreDir);
const outputPath = join(repoDir, 'MVP', 'Resources', 'ThirdPartyNotices.md');

// 许可文件候选名（LICENSE/LICENCE/COPYING/COPYRIGHT/NOTICE 及其变体），排除同名脚本。
const licenseFileNamePattern = /^(licen[cs]e|copying|copyright|notice)/i;
const scriptFileSuffixPattern = /\.(m?js|cjs|mts|cts|ts|json)$/i;
// 版权行：要求带年份或 ©（"Copyright (c) 2018 …"、"Copyright 2010-2024 …"、"© 2014 …"），
// 避免把 Apache 等许可正文里以 "(c)" 或 "copyright" 开头的普通条款行误认成版权声明。
const copyrightLinePattern =
  /^\s*(?:copyright\s*\(c\)|copyright\s*©|copyright\s+\d{4}|\(c\)\s*\d{4}|©\s*\d{4})/i;
const copyrightPlaceholderPattern =
  /\[(?:yyyy|year|name of copyright owner|name of owner|owner name)\]|<year>|<copyright holders?>|\byyyy\b/i;
// 仅用于去重键的许可标题行（"MIT License"、"The MIT License (MIT)" 等），使同文本异标题的包归并。
const licenseTitlePattern = /^[=#*\s]*\(?\s*(?:the\s+)?[a-z0-9.+\- ]{0,40}licen[cs]e[a-z0-9.+\- ()]*\)?[=#*\s]*$/i;

const warnings = [];

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function compareStrings(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

// 版本号按段比较（数值段按数值，其余按字典序），足够用于展示排序。
function compareVersions(a, b) {
  const left = a.split('.');
  const right = b.split('.');
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const l = left[index] ?? '';
    const r = right[index] ?? '';
    const ln = Number(l);
    const rn = Number(r);
    if (Number.isFinite(ln) && Number.isFinite(rn) && ln !== rn) return ln - rn;
    if (l !== r) return compareStrings(l, r);
  }
  return 0;
}

function readTextFile(path) {
  return readFileSync(path, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
}

// 从 fromDir 起逐级向上查找 node_modules/<name>，与 Node 的解析顺序一致。
function resolvePackage(fromDir, name) {
  let current = fromDir;
  for (;;) {
    const candidate = join(current, 'node_modules', name);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function licenseFilePriority(name) {
  const lower = name.toLowerCase();
  if (lower === 'license' || lower === 'licence') return 0;
  if (lower.startsWith('license') || lower.startsWith('licence')) return 1;
  if (lower.startsWith('copying') || lower.startsWith('copyright')) return 2;
  if (lower.startsWith('notice')) return 3;
  return 4;
}

function findLicenseFiles(dir) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((name) => licenseFileNamePattern.test(name) && !scriptFileSuffixPattern.test(name))
    .sort((a, b) => licenseFilePriority(a) - licenseFilePriority(b) || compareStrings(a, b));
}

function packageHomepage(manifest) {
  if (typeof manifest.homepage === 'string' && manifest.homepage !== '') return manifest.homepage;
  const repository = manifest.repository;
  let url = '';
  if (typeof repository === 'string') {
    url = repository;
  } else if (repository !== null && typeof repository === 'object' && typeof repository.url === 'string') {
    url = repository.url;
  }
  if (url === '') return '';
  return url.replace(/^git\+/, '').replace(/^git:\/\//, 'https://').replace(/\.git$/, '');
}

// 从许可文件中提取版权行：先看主许可文件，找不到再尝试其余文件；占位模板行不计。
function extractCopyright(pkg) {
  for (const file of pkg.licenseFiles) {
    const found = [];
    for (const line of readTextFile(join(pkg.path, file)).split('\n')) {
      const trimmed = line.trim();
      if (!copyrightLinePattern.test(trimmed)) continue;
      if (copyrightPlaceholderPattern.test(trimmed)) continue;
      if (!found.includes(trimmed)) found.push(trimmed);
    }
    if (found.length > 0) return found.join(' / ');
  }
  return '';
}

// 仅移除作为独立词出现的包名（避免误伤正文里恰好包含该串的普通单词）。
function removePackageName(text, name) {
  if (name === '') return text;
  const pattern = new RegExp(escapeRegExp(name), 'gi');
  return text.replace(pattern, (match, offset, whole) => {
    const before = offset > 0 ? whole[offset - 1] : '';
    const after = offset + match.length < whole.length ? whole[offset + match.length] : '';
    if (/[a-z0-9]/i.test(before) || /[a-z0-9]/i.test(after)) return match;
    return '';
  });
}

// 去掉首个非空行若为许可标题（只影响去重键，不改展示文本）。
function dropLeadingTitle(text) {
  const lines = text.split('\n');
  let index = 0;
  while (index < lines.length && lines[index].trim() === '') index += 1;
  if (index >= lines.length) return text;
  const first = lines[index].trim();
  if (first.length <= 60 && licenseTitlePattern.test(first)) lines[index] = '';
  return lines.join('\n');
}

// 去重键：许可文本去掉包名、版权行与标题行后，压缩为小写字母数字串。
function dedupeKey(pkg) {
  const parts = pkg.licenseFiles.map((file) => {
    let text = readTextFile(join(pkg.path, file));
    // 只移除完整包名（如 @chevrotain/types），不拆 scoped 段，避免误删许可文本中的普通单词。
    text = removePackageName(text, pkg.name);
    text = text.split('\n').filter((line) => !copyrightLinePattern.test(line)).join('\n');
    return dropLeadingTitle(text);
  });
  return parts.join('\n\n').toLowerCase().replace(/[^a-z0-9]+/g, '');
}

const rootManifest = JSON.parse(readTextFile(join(coreDir, 'package.json')));
const directNames = new Set(Object.keys(rootManifest.dependencies ?? {}));
const packagesByPath = new Map();

function collectPackage(dir, requestedName, isDirect) {
  const known = packagesByPath.get(dir);
  if (known !== undefined) {
    // 同一目录可能同时被根依赖与传递依赖解析到（hoisting），标记为直接依赖。
    if (isDirect) known.isDirect = true;
    return;
  }
  let manifest;
  try {
    manifest = JSON.parse(readTextFile(join(dir, 'package.json')));
  } catch {
    warnings.push(`无法读取 ${dir}/package.json，已跳过（依赖 ${requestedName}）`);
    return;
  }
  const pkg = {
    name: typeof manifest.name === 'string' && manifest.name !== '' ? manifest.name : requestedName,
    version: typeof manifest.version === 'string' ? manifest.version : '',
    license: typeof manifest.license === 'string' ? manifest.license : '',
    homepage: packageHomepage(manifest),
    licenseFiles: findLicenseFiles(dir),
    isDirect,
    path: dir,
  };
  pkg.copyright = extractCopyright(pkg);
  // 多个许可文件（如 dompurify 的 LICENSE + LICENSE-MPL、es-toolkit 的 LICENSE + NOTICE）全部收录。
  pkg.licenseText = pkg.licenseFiles
    .map((file, index) => {
      const text = readTextFile(join(dir, file));
      if (pkg.licenseFiles.length === 1) return text;
      return index === 0 ? text : `\n\n--- ${pkg.name}/${file} ---\n\n${text}`;
    })
    .join('');
  packagesByPath.set(dir, pkg);
  const dependencies = manifest.dependencies;
  if (dependencies !== null && typeof dependencies === 'object') {
    for (const name of Object.keys(dependencies)) {
      const target = resolvePackage(dir, name);
      if (target === null) {
        warnings.push(`依赖 ${name}（${pkg.name} 所需）在 node_modules 中未找到`);
        continue;
      }
      collectPackage(target, name, false);
    }
  }
}

for (const name of Object.keys(rootManifest.dependencies ?? {})) {
  const target = resolvePackage(coreDir, name);
  if (target === null) {
    warnings.push(`直接依赖 ${name} 在 node_modules 中未找到`);
    continue;
  }
  collectPackage(target, name, directNames.has(name));
}

const packages = [...packagesByPath.values()];
packages.sort(
  (a, b) =>
    compareStrings(a.name, b.name) || compareVersions(a.version, b.version) || compareStrings(a.path, b.path),
);

const groupsByKey = new Map();
for (const pkg of packages) {
  const key = dedupeKey(pkg);
  let group = groupsByKey.get(key);
  if (group === undefined) {
    group = { packages: [] };
    groupsByKey.set(key, group);
  }
  group.packages.push(pkg);
}
// packages 已排序，因此每组内成员有序；组之间按首个成员的名称排序。
const groups = [...groupsByKey.values()];
groups.sort(
  (a, b) =>
    compareStrings(a.packages[0].name, b.packages[0].name) ||
    compareVersions(a.packages[0].version, b.packages[0].version),
);

function groupLabel(group) {
  for (const pkg of group.packages) {
    if (pkg.license !== '') return pkg.license;
  }
  return '未声明';
}

function tableCell(text) {
  return text.replace(/\|/g, '\\|');
}

function directMark(pkg) {
  return pkg.isDirect ? ' \\*' : '';
}

const directCount = packages.filter((pkg) => pkg.isDirect).length;

const lines = [];
lines.push('# 第三方许可致谢（Third-Party Notices）', '');
lines.push('本文件列出 Inkpot 应用打包分发的第三方依赖及其许可信息，由脚本自动生成，请勿手工编辑。', '');
lines.push('- 生成脚本：`CoreEditor/scripts/generate-notices.mjs`');
lines.push(
  '- 再生成：在 `CoreEditor/` 目录下执行 `node .yarn/releases/yarn-4.18.0.cjs notices`（等价于 `node scripts/generate-notices.mjs`）',
);
lines.push(
  '- 收录范围：`CoreEditor/package.json` 中 `dependencies` 声明的生产依赖及其传递依赖（对应 Vite 打包输入的依赖闭包）；`devDependencies` 中的构建、测试工具不打包进应用，不收录。',
);
lines.push('- 数据来源：各包在 `node_modules` 中的 `package.json`（名称、版本、许可证声明、主页）与包内许可文件（LICENSE、COPYING、NOTICE 等）原文。');
lines.push('- 许可文本按内容去重（忽略版权行、许可标题与空白差异），同一份文本只展示一次，组内各包的版权声明见对应表格行。');
lines.push('- 版权声明提取自各包许可文件；未能提取时以包名代替。');
lines.push('- 包名带 `\\*` 表示 `package.json` 中声明的直接依赖，其余为传递依赖；同名包若有多个版本（如 katex），按版本分别列出。');
lines.push('');
lines.push(
  `共收录 ${packages.length} 个包（直接依赖 ${directCount} 个、传递依赖 ${packages.length - directCount} 个），许可文本去重后共 ${groups.length} 组。`,
  '');
lines.push('## 许可证类型分布', '');
lines.push('| 许可证声明 | 包数 |', '| --- | --- |');
const distribution = new Map();
for (const group of groups) {
  const label = groupLabel(group);
  distribution.set(label, (distribution.get(label) ?? 0) + group.packages.length);
}
const distributionRows = [...distribution.entries()].sort((a, b) => b[1] - a[1] || compareStrings(a[0], b[0]));
for (const [label, count] of distributionRows) {
  lines.push(`| ${tableCell(label)} | ${count} |`);
}
lines.push('');

groups.forEach((group, index) => {
  const label = groupLabel(group);
  lines.push(`## ${index + 1}. ${label}（${group.packages.length} 个包）`, '');
  lines.push('| 包名 | 版本 | 版权声明 |', '| --- | --- | --- |');
  for (const pkg of group.packages) {
    const copyright = pkg.copyright !== '' ? pkg.copyright : pkg.name;
    lines.push(`| ${tableCell(pkg.name)}${directMark(pkg)} | ${tableCell(pkg.version)} | ${tableCell(copyright)} |`);
  }
  lines.push('');
  const sample = group.packages[0];
  if (sample.licenseText.trim() === '') {
    lines.push('该组包内未找到许可文件，许可证声明见附录索引。', '');
  } else {
    const fileNames = sample.licenseFiles.join('、');
    lines.push(`许可文本以 ${sample.name} 包内 ${fileNames} 为样本（其余包的版权声明见上表）：`, '');
    let fence = '```';
    while (sample.licenseText.includes(fence)) fence = `\`${fence}`;
    lines.push(`${fence}text`);
    lines.push(sample.licenseText.replace(/\s+$/, ''));
    lines.push(fence, '');
  }
});

lines.push('## 附录：包索引', '');
lines.push('按包名排序的全部收录包，「类型」一栏「直接」为 `package.json` 声明的直接依赖，「传递」为传递依赖：', '');
lines.push('| 包名 | 版本 | 许可证声明 | 主页 | 类型 |', '| --- | --- | --- | --- | --- |');
for (const pkg of packages) {
  const license = pkg.license !== '' ? pkg.license : '未声明';
  const homepage = pkg.homepage !== '' ? pkg.homepage : '—';
  const kind = pkg.isDirect ? '直接' : '传递';
  lines.push(`| ${tableCell(pkg.name)} | ${tableCell(pkg.version)} | ${tableCell(license)} | ${tableCell(homepage)} | ${kind} |`);
}
lines.push('');

const content = `${lines.join('\n')}\n`;
mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, content);

console.log(`已生成 ${outputPath}`);
console.log(
  `收录 ${packages.length} 个包（直接 ${directCount}、传递 ${packages.length - directCount}），许可文本 ${groups.length} 组，` +
    `${Math.round((Buffer.byteLength(content, 'utf8') / 1024) * 10) / 10} KB`,
);
for (const warning of warnings) console.warn(`警告：${warning}`);
