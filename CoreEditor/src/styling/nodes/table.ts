import { createBlockWrappers, createLineDeco } from '../matchers/lezer';
import { createBlockPlugin, createDecoPlugin } from '../helper';

/**
 * Always use monospace font for Table.
 */
export const tableStyle = [
  createBlockPlugin(() => createBlockWrappers('Table', 'cm-md-tableWrapper')),
  createDecoPlugin(() => createLineDeco('Table', 'cm-md-monospace cm-md-table')),
];

