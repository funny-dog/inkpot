/** 上游配色与适配范围见 ../themes/NOTICES.md；字体和 Typora 专用样式不随应用分发。 */
export interface ThemePalette {
  background: string;
  text: string;
  muted: string;
  accent: string;
  heading: string;
  border: string;
  surface: string;
  code: string;
  codeText: string;
  quote: string;
  selection: string;
  keyword: string;
  string: string;
  comment: string;
  number: string;
  function: string;
  type: string;
}

// 未单独映射的语法类别沿用 Inkpot 的明暗代码配色。
const lightCode = { keyword: '#a626a4', string: '#50a14f', comment: '#6e7781', number: '#986801', function: '#4078f2', type: '#c18401' };
const darkCode = { keyword: '#c678dd', string: '#98c379', comment: '#7f848e', number: '#d19a66', function: '#61afef', type: '#e5c07b' };
const dracula: ThemePalette = {
  background: '#282a36', text: '#f8f8f2', muted: '#8798c6', accent: '#8be9fd', heading: '#bd93f9', border: '#44475a',
  surface: '#44475a', code: '#282a36', codeText: '#f8f8f2', quote: '#44475a', selection: '#44475a',
  keyword: '#ff79c6', string: '#f1fa8c', comment: '#8798c6', number: '#bd93f9', function: '#50fa7b', type: '#8be9fd',
};

export const themePalettes: Readonly<Partial<Record<string, { light: ThemePalette; dark: ThemePalette }>>> = {
  lapis: {
    light: {
      ...lightCode, background: '#ffffff', text: '#40464f', muted: '#64748b', accent: '#4870ac', heading: '#4870ac', border: '#e3e8f0',
      surface: '#f6f8fa', code: '#f6f8fa', codeText: '#40464f', quote: '#f6f8fa', selection: '#a2b6d4',
    },
    dark: {
      ...darkCode, background: '#1e222a', text: '#e4e4e4', muted: '#8393ad', accent: '#8393ad', heading: '#abbad4', border: '#47556d',
      surface: '#181c24', code: '#080e1d', codeText: '#abbad4', quote: '#2a2f3b', selection: '#346895',
    },
  },
  ursine: {
    light: {
      ...lightCode, background: '#fbfbfb', text: '#333333', muted: '#827676', accent: '#c23d43', heading: '#333333', border: '#dddddd',
      surface: '#f7f7f7', code: '#fafafa', codeText: '#3a3432', quote: '#f7f7f7', selection: '#fbb6b7',
      keyword: '#db2d20', number: '#a16a94',
    },
    dark: {
      ...darkCode, background: '#1e2022', text: '#dddddd', muted: '#888e9c', accent: '#6bcafb', heading: '#dddddd', border: '#3c3c3c',
      surface: '#2b2b2b', code: '#282a36', codeText: '#f8f8f2', quote: '#2b2b2b', selection: '#285194',
      keyword: '#ff79c6', string: '#f1fa8c', number: '#bd93f9', function: '#50fa7b', type: '#ffb86c',
    },
  },
  notion: {
    light: {
      ...lightCode, background: '#ffffff', text: '#37352f', muted: '#73726e', accent: '#37352f', heading: '#37352f', border: '#e9e9e7',
      surface: '#f7f6f3', code: '#f7f6f3', codeText: '#b83b3b', quote: '#ffffff', selection: '#c0e5f4',
    },
    dark: {
      ...darkCode, background: '#2f3437', text: '#ebebeb', muted: '#acaeaf', accent: '#ebebeb', heading: '#ebebeb', border: '#4b5053',
      surface: '#3f4447', code: '#3f4447', codeText: '#ff9999', quote: '#2f3437', selection: '#2e5767',
    },
  },
  pie: {
    light: {
      ...lightCode, background: '#ffffff', text: '#262626', muted: '#595959', accent: '#cb2923', heading: '#262626', border: '#d9d9d9',
      surface: '#fafafa', code: '#f5f5f5', codeText: '#434343', quote: '#fff2f0', selection: '#faa295',
    },
    dark: {
      ...darkCode, background: '#272b40', text: '#d9d9d9', muted: '#999999', accent: '#ff7a66', heading: '#f0f0f0', border: '#393550',
      surface: '#3b4057', code: '#1f2335', codeText: '#d9d9d9', quote: '#3b4057', selection: '#6d3d46',
    },
  },
  drake: {
    light: {
      ...lightCode, background: '#ffffff', text: '#333333', muted: '#777777', accent: '#d63200', heading: '#273849', border: '#dfe2e5',
      surface: '#f8f8f8', code: '#f6f8fa', codeText: '#24292e', quote: '#fdefee', selection: '#f7c4c0',
    },
    dark: {
      ...darkCode, background: '#2b2b2b', text: '#acb7c4', muted: '#9a9a9a', accent: '#58a1d6', heading: '#bbc9d7', border: '#383838',
      surface: '#222222', code: '#222222', codeText: '#a9b7c6', quote: '#2c3238', selection: '#30495f',
      keyword: '#cc7832', number: '#6897bb', function: '#ffd760', type: '#aabbcc',
    },
  },
  phycat: {
    light: {
      ...lightCode, background: '#ffffff', text: '#333333', muted: '#595959', accent: '#008145', heading: '#008145', border: '#80c3a4',
      surface: '#edf6f1', code: '#edf6f1', codeText: '#006a39', quote: '#edf6f1', selection: '#80c3a4',
    },
    dark: {
      ...darkCode, background: '#0f111a', text: '#d6deeb', muted: '#7e8c9f', accent: '#00f3ff', heading: '#00f3ff', border: '#1f2233',
      surface: '#1f2233', code: '#0f111a', codeText: '#d6deeb', quote: '#1f2233', selection: '#1d3b53',
      keyword: '#c792ea', string: '#ecc48d', comment: '#7e8c9f', number: '#f78c6c', function: '#82aaff', type: '#addb67',
    },
  },
  dracula: { light: dracula, dark: dracula },
};
