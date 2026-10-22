// 实时模式自带的少量界面文案，按浏览器语言选择
const strings = {
  'default': {
    goToFootnoteDefinition: 'Go to definition [%s]',
    backToFootnoteReference: 'Back to reference [%s]',
  },
  'zh-CN': {
    goToFootnoteDefinition: '跳转到定义 [%s]',
    backToFootnoteReference: '返回引用 [%s]',
  },
  'zh-TW': {
    goToFootnoteDefinition: '前往定義 [%s]',
    backToFootnoteReference: '返回引用 [%s]',
  },
};

type LocalizableKey = keyof typeof strings['default'];

export function localized(key: LocalizableKey): string {
  const language = navigator.language.startsWith('zh')
    ? (/TW|HK|Hant/i.test(navigator.language) ? 'zh-TW' : 'zh-CN') : 'default';
  return (language === 'zh-CN' ? strings['zh-CN'] : language === 'zh-TW' ? strings['zh-TW'] : strings.default)[key];
}
