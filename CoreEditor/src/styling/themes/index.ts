import { EditorTheme } from '../types';

import GitHubLight from './github-light';
import GitHubDark from './github-dark';
import XcodeLight from './xcode-light';
import XcodeDark from './xcode-dark';

const themes: { [key: string]: (() => EditorTheme) | undefined } = {
  'github-light': GitHubLight,
  'github-dark': GitHubDark,
  'xcode-light': XcodeLight,
  'xcode-dark': XcodeDark,
};

export function loadTheme(name: string): EditorTheme {
  return (themes[name] ?? GitHubLight)();
}

export type { EditorTheme };
