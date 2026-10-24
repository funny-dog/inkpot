// 界面语言由原生应用在创建编辑器前传入；不检测或改写文档内容。
const english = {
  '开始写作…': 'Start writing…',
  'Markdown 文本编辑器': 'Markdown text editor',
  '打开文件': 'Open File',
  '打开文件夹': 'Open Folder',
  '切换源码模式': 'Toggle Source Mode',
  '设置': 'Settings',
  '常用快捷键': 'Keyboard Shortcuts',
  '正则表达式无效': 'Invalid regular expression',
  '未找到匹配项': 'No matches found',
  '当前文档查找与替换': 'Find and replace in this document',
  '查找文本': 'Find',
  '替换为': 'Replace with',
  '区分大小写': 'Match Case',
  '整词': 'Whole Word',
  '正则': 'Regex',
  '上一个': 'Previous',
  '下一个': 'Next',
  '完成': 'Done',
  '替换': 'Replace',
  '全部替换': 'Replace All',
  '当前匹配项': 'current match',
  '所在行': 'on line',
  '已替换第 $ 行的匹配项': 'replaced match on line $',
  '已替换 $ 处匹配项': 'replaced $ matches',
  '纯文本': 'Plain Text',
  '代码语言：{0}，点击修改': 'Code language: {0}. Click to change.',
  '修改代码语言；代码中按 ⌘Enter 返回正文': 'Change code language; press ⌘Enter in the code to return to the text',
  '⌘单击或 ⌘Enter 打开链接': '⌘-click or press ⌘Enter to open link',
  '⌘单击打开链接': '⌘-click to open link',
  '双击图片编辑 Markdown 路径': 'Double-click the image to edit its Markdown path',
  '图片': 'Image',
  '图片无法读取：{0}': 'Unable to load image: {0}',
  '图片无法读取，双击修改路径': 'Unable to load image. Double-click to edit its path.',
  '任务勾选': 'Task checkbox',
  '脚注：{0}': 'Footnote: {0}',
  '目录': 'Table of Contents',
  '暂无标题': 'No headings',
  '跳转到此标题': 'Go to heading',
  '（空标题）': '(Untitled heading)',
  '公式源码：{0}': 'Math source: {0}',
  '点击编辑公式源码': 'Click to edit math source',
  'Mermaid 图表：{0}': 'Mermaid diagram: {0}',
  '点击或按 Enter 编辑图表源码': 'Click or press Enter to edit diagram source',
  '图表文本超过 50,000 字符限制': 'Diagram exceeds the 50,000-character limit',
  '图表暂时无法显示，请编辑源码检查语法或简化图表。\n{0}': 'Unable to display this diagram. Edit the source to check its syntax or simplify it.\n{0}',
  '列 {0}': 'Column {0}',
  'Markdown 表格': 'Markdown table',
  '第 {0} 行，第 {1} 列': 'Row {0}, column {1}',
  'Tab 切换单元格 · Enter 下一行 · ⌘Enter 返回正文 · 格式 → 表格增删行列': 'Tab: next cell · Enter: next row · ⌘Enter: return to text · Format → Table: add or remove rows and columns',
  '请先结束输入或等待编辑器就绪，再插入图片。': 'Finish composing or wait for the editor to be ready before inserting an image.',
  '编辑器尚未就绪。': 'The editor is not ready.',
  '请先确认输入法候选文字，再保存或关闭。': 'Confirm the input method composition before saving or closing.',
  '语言文件 {0} 缺少 {1}': 'Language file {0} is missing {1}',
  '图片来源不受支持，已取消导出。': 'Unsupported image source. Export was cancelled.',
  '图片无法读取': 'Unable to read image',
  '图片体积超过导出限制（单张 20 MB，总计 50 MB）': 'Images exceed the export limit (20 MB per image, 50 MB total)',
  '图片编码失败': 'Unable to encode image',
  '读取失败': 'Unable to read',
  '无法导出图片“{0}”：{1}': 'Unable to export image “{0}”: {1}',
  '请先确认输入法候选文字，再导出。': 'Confirm the input method composition before exporting.',
  '正在导出，请等待完成。': 'Export is in progress. Please wait.',
  '文档尚未完成解析，请稍后重试导出。': 'The document is still being parsed. Try exporting again shortly.',
  '文档已关闭或导出期间发生编辑，请重新导出。': 'The document was closed or edited during export. Please export again.',
  '图表或公式渲染超时，请检查内容后重试。': 'Diagram or math rendering timed out. Check the content and try again.',
  '导出期间发生编辑，请重新导出。': 'The document was edited during export. Please export again.',
  '导出期间发生编辑或文档已关闭，请重新导出。': 'The document was edited or closed during export. Please export again.',
  '文档': 'Document',
};

let language: 'en' | 'zh-Hans' = 'en';

export function setEditorLanguage(value: string) {
  language = value.startsWith('zh') ? 'zh-Hans' : 'en';
  document.documentElement.lang = language;
}

export function editorLanguage() { return language; }

export function t(key: keyof typeof english, ...values: (string | number)[]) {
  const template = language === 'zh-Hans' ? key : english[key];
  return template.replace(/\{(\d+)\}/g, (_match, index: string) => String(values[Number(index)] ?? ''));
}
