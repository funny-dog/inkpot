import { t } from './localization';
import { EditorView, KeyBinding, runScopeHandlers, ViewUpdate } from '@codemirror/view';
import { closeSearchPanel, findNext, findPrevious, getSearchQuery, openSearchPanel, replaceAll, replaceNext, search, SearchQuery, setSearchQuery } from '@codemirror/search';
import { isolateHistory } from '@codemirror/commands';

function navigate(view: EditorView, forward: boolean) {
  const found = (forward ? findNext : findPrevious)(view);
  const status = view.dom.querySelector('.cm-inkpot-search [role=status]');
  if (status !== null) status.textContent = !getSearchQuery(view.state).valid && getSearchQuery(view.state).regexp ? t('正则表达式无效') : found ? '' : t('未找到匹配项');
  return found;
}

export const searchCommands = {
  find: openSearchPanel,
  findNext: (view: EditorView) => navigate(view, true),
  findPrevious: (view: EditorView) => navigate(view, false),
};

export const searchBindings: KeyBinding[] = [
  { key: 'Mod-f', run: openSearchPanel, scope: 'editor search-panel' },
  { key: 'Mod-g', run: searchCommands.findNext, shift: searchCommands.findPrevious, scope: 'editor search-panel', preventDefault: true },
  { key: 'Escape', run: closeSearchPanel, scope: 'editor search-panel' },
];

function createPanel(view: EditorView) {
  const dom = document.createElement('div');
  dom.className = 'cm-inkpot-search';
  dom.setAttribute('role', 'search');
  dom.setAttribute('aria-label', t('当前文档查找与替换'));
  const query = getSearchQuery(view.state);
  const find = document.createElement('input');
  const replace = document.createElement('input');
  find.value = query.search;
  replace.value = query.replace;
  find.setAttribute('main-field', 'true');
  for (const [field, name, label] of [[find, 'search', t('查找文本')], [replace, 'replace', t('替换为')]] as const) {
    field.name = name;
    field.placeholder = label;
    field.setAttribute('aria-label', label);
    field.autocomplete = 'off';
    field.spellcheck = false;
    field.addEventListener('input', event => { if (!(event as InputEvent).isComposing) commit(); });
    field.addEventListener('compositionend', () => commit());
  }
  const options = document.createElement('div');
  options.className = 'cm-inkpot-search-options';
  const toggles = (['caseSensitive', 'wholeWord', 'regexp'] as const).map((name, index) => {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.name = name;
    input.checked = query[name];
    input.addEventListener('change', () => commit());
    label.append(input, [t('区分大小写'), t('整词'), t('正则')][index]);
    options.append(label);
    return input;
  });
  const [caseSensitive, wholeWord, regexp] = toggles;
  const status = document.createElement('span');
  status.setAttribute('role', 'status');
  function commit() {
    const current = new SearchQuery({ search: find.value, replace: replace.value, literal: true,
      caseSensitive: caseSensitive.checked, wholeWord: wholeWord.checked, regexp: regexp.checked });
    view.dispatch({ effects: setSearchQuery.of(current) });
    find.setAttribute('aria-invalid', String(current.regexp && !current.valid && current.search !== ''));
    status.textContent = current.regexp && !current.valid && current.search !== '' ? t('正则表达式无效') : '';
  }
  function run(command: typeof findNext, field = find) {
    if (view.composing) return;
    commit();
    if (!getSearchQuery(view.state).valid) return;
    const replacing = command === replaceNext || command === replaceAll;
    // 每次替换独立撤销，不与相邻输入或其他替换合并。
    if (replacing) view.dispatch({ annotations: isolateHistory.of('full') });
    const found = command(view);
    if (replacing) view.dispatch({ annotations: isolateHistory.of('full') });
    status.textContent = found ? '' : t('未找到匹配项');
    field.focus();
  }
  function button(label: string, name: string, action: () => void) {
    const item = document.createElement('button');
    item.type = 'button';
    item.name = name;
    item.className = 'cm-inkpot-search-action';
    item.textContent = label;
    item.addEventListener('click', action);
    return item;
  }
  // 上一个/下一个只显示箭头图标，名称留给读屏与悬停提示。
  function arrow(label: string, name: string, shortcut: string, points: string, action: () => void) {
    const item = button('', name, action);
    item.className = '';
    item.setAttribute('aria-label', label);
    item.title = `${label} (${shortcut})`;
    item.innerHTML = `<svg aria-hidden="true" width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><polyline points="${points}"></polyline></svg>`;
    return item;
  }
  // 输入框外包一层圆角框；查找框带放大镜，替换框左侧留出同样宽度对齐。
  function field(input: HTMLInputElement, icon: boolean) {
    const box = document.createElement('label');
    box.className = icon ? 'cm-inkpot-search-field' : 'cm-inkpot-search-field cm-inkpot-search-replace-field';
    if (icon) box.innerHTML = '<svg aria-hidden="true" width="13" height="13" viewBox="0 0 30 30" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><circle cx="13" cy="13" r="9"></circle><line x1="19.5" y1="19.5" x2="27" y2="27"></line></svg>';
    box.append(input);
    return box;
  }
  function part(className: string) {
    const element = document.createElement('div');
    element.className = className;
    return element;
  }
  const navigation = part('cm-inkpot-search-nav');
  navigation.append(arrow(t('上一个'), 'previous', '⇧⌘G', '6.5,1.5 3,5 6.5,8.5', () => run(searchCommands.findPrevious)),
    arrow(t('下一个'), 'next', '⌘G', '3.5,1.5 7,5 3.5,8.5', () => run(searchCommands.findNext)));
  const first = document.createElement('div');
  const second = document.createElement('div');
  first.append(field(find, true), options, part('cm-inkpot-search-divider'), navigation, part('cm-inkpot-search-spacer'),
    button(t('完成'), 'close', () => closeSearchPanel(view)));
  second.append(field(replace, false), button(t('替换'), 'replace', () => run(replaceNext, replace)), button(t('全部替换'), 'replaceAll', () => run(replaceAll, replace)), status);
  dom.append(first, second);
  dom.addEventListener('keydown', event => {
    if (event.isComposing || event.keyCode === 229) return;
    if (event.key === 'Enter') {
      event.preventDefault();
      run(event.target === replace ? replaceNext : event.shiftKey ? searchCommands.findPrevious : searchCommands.findNext, event.target === replace ? replace : find);
    } else if (runScopeHandlers(view, event, 'search-panel')) {
      event.preventDefault();
      event.stopPropagation();
    }
  });
  return {
    dom,
    top: true,
    mount() { find.focus(); find.select(); },
    update(update: ViewUpdate) {
      if (!update.transactions.some(transaction => transaction.effects.some(effect => effect.is(setSearchQuery)))) return;
      const current = getSearchQuery(view.state);
      if (find.value !== current.search) find.value = current.search;
      if (replace.value !== current.replace) replace.value = current.replace;
      for (const toggle of toggles) toggle.checked = current[toggle.name as 'caseSensitive' | 'wholeWord' | 'regexp'];
    },
  };
}

export const documentSearch = search({ top: true, literal: true, createPanel });

/** 查找栏浅色样式（深色覆盖在 theme.ts），按设计稿：圆角输入框、选项胶囊、箭头按钮组与右侧“完成”。 */
export const searchPanelTheme = {
  '.cm-inkpot-search': { padding: '8px 12px', font: '13px -apple-system, "PingFang SC", system-ui, sans-serif' },
  '.cm-inkpot-search > div': { display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' },
  '.cm-inkpot-search > div + div': { marginTop: '6px' },
  '.cm-inkpot-search-field': { flex: '1 1 260px', maxWidth: '420px', minWidth: '0', height: '26px', boxSizing: 'border-box', display: 'flex', alignItems: 'center', gap: '6px', padding: '0 8px', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '6px', backgroundColor: '#ffffff', color: '#6e6e73' },
  '.cm-inkpot-search-field:focus-within': { borderColor: '#2b5a8c', boxShadow: '0 0 0 3px rgba(43, 90, 140, 0.2)' },
  '.cm-inkpot-search-replace-field': { paddingLeft: '27px' },
  '.cm-inkpot-search-field svg': { flexShrink: '0' },
  '.cm-inkpot-search-field input': { flex: '1', minWidth: '0', border: '0', outline: '0', padding: '0', background: 'transparent', font: 'inherit', color: '#1d1d1f' },
  '.cm-inkpot-search-field input[aria-invalid=true]': { color: '#c4342d' },
  '.cm-inkpot-search-options': { display: 'flex', gap: '2px' },
  '.cm-inkpot-search-options label': { position: 'relative', height: '24px', padding: '0 8px', display: 'inline-flex', alignItems: 'center', borderRadius: '5px', color: '#6e6e73', fontSize: '12px', fontWeight: '500' },
  // 复选框保留在标签内供键盘与读屏操作，视觉上由整个胶囊表示开关状态。
  '.cm-inkpot-search-options input': { position: 'absolute', inset: '0', margin: '0', opacity: '0' },
  '.cm-inkpot-search-options label:has(input:checked)': { backgroundColor: 'rgba(43, 90, 140, 0.14)', color: '#2b5a8c', fontWeight: '600' },
  '.cm-inkpot-search-options label:has(input:focus-visible)': { outline: '2px solid #2b5a8c' },
  '.cm-inkpot-search-divider': { width: '1px', height: '16px', margin: '0 4px', backgroundColor: 'rgba(0, 0, 0, 0.12)' },
  '.cm-inkpot-search-nav': { display: 'flex', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '6px', overflow: 'hidden', backgroundColor: '#ffffff' },
  '.cm-inkpot-search-nav button': { width: '30px', height: '24px', padding: '0', border: '0', background: 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#3a3a3c' },
  '.cm-inkpot-search-nav button + button': { borderLeft: '1px solid rgba(0, 0, 0, 0.12)' },
  '.cm-inkpot-search-nav button:active, .cm-inkpot-search-action:active': { backgroundColor: 'rgba(0, 0, 0, 0.06)' },
  '.cm-inkpot-search-spacer': { flexGrow: '1' },
  '.cm-inkpot-search-action': { height: '24px', padding: '0 12px', border: '1px solid rgba(0, 0, 0, 0.12)', borderRadius: '6px', backgroundColor: '#ffffff', font: 'inherit', color: '#1d1d1f' },
  '.cm-inkpot-search [role=status]': { marginLeft: '6px', fontSize: '12px', color: '#6e6e73' },
};
