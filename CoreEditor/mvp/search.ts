import { EditorView, KeyBinding, runScopeHandlers, ViewUpdate } from '@codemirror/view';
import { closeSearchPanel, findNext, findPrevious, getSearchQuery, openSearchPanel, replaceAll, replaceNext, search, SearchQuery, setSearchQuery } from '@codemirror/search';
import { isolateHistory } from '@codemirror/commands';

function navigate(view: EditorView, forward: boolean) {
  const found = (forward ? findNext : findPrevious)(view);
  const status = view.dom.querySelector('.cm-mvp-search [role=status]');
  if (status !== null) status.textContent = found ? '' : '未找到匹配项';
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
  dom.className = 'cm-mvp-search';
  dom.setAttribute('role', 'search');
  dom.setAttribute('aria-label', '当前文档查找与替换');
  const query = getSearchQuery(view.state);
  const find = document.createElement('input');
  const replace = document.createElement('input');
  find.value = query.search;
  replace.value = query.replace;
  find.setAttribute('main-field', 'true');
  for (const [field, name, label] of [[find, 'search', '查找文本'], [replace, 'replace', '替换为']] as const) {
    field.name = name;
    field.placeholder = label;
    field.setAttribute('aria-label', label);
    field.autocomplete = 'off';
    field.spellcheck = false;
    field.addEventListener('input', event => { if (!(event as InputEvent).isComposing) commit(); });
    field.addEventListener('compositionend', () => commit());
  }
  const status = document.createElement('span');
  status.setAttribute('role', 'status');
  function commit() {
    view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: find.value, replace: replace.value, literal: true })) });
    status.textContent = '';
  }
  function run(command: typeof findNext, field = find) {
    if (view.composing) return;
    commit();
    const replacing = command === replaceNext || command === replaceAll;
    // 每次替换独立撤销，不与相邻输入或其他替换合并。
    if (replacing) view.dispatch({ annotations: isolateHistory.of('full') });
    const found = command(view);
    if (replacing) view.dispatch({ annotations: isolateHistory.of('full') });
    status.textContent = found ? '' : '未找到匹配项';
    field.focus();
  }
  function button(label: string, name: string, action: () => void) {
    const item = document.createElement('button');
    item.type = 'button';
    item.name = name;
    item.textContent = label;
    item.addEventListener('click', action);
    return item;
  }
  const first = document.createElement('div');
  const second = document.createElement('div');
  first.append(find, button('上一个', 'previous', () => run(searchCommands.findPrevious)), button('下一个', 'next', () => run(searchCommands.findNext)),
    button('关闭', 'close', () => closeSearchPanel(view)));
  second.append(replace, button('替换', 'replace', () => run(replaceNext, replace)), button('全部替换', 'replaceAll', () => run(replaceAll, replace)), status);
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
    },
  };
}

export const documentSearch = search({ top: true, literal: true, createPanel });
