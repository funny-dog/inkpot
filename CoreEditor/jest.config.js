/** @type { import('ts-jest').JestConfigWithTsJest } */

// eslint-disable-next-line no-undef
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  setupFiles: ['<rootDir>/test/utils/setup.ts'],
  testMatch: ['<rootDir>/test/**/*.test.ts'],
  moduleNameMapper: {
    // 与生产构建一致使用浏览器版 Turndown，DOM 由 jsdom 提供。
    '^turndown$': '<rootDir>/node_modules/turndown/lib/turndown.browser.cjs.js',
  },
};
