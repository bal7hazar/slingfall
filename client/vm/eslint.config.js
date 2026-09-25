// ESLint (v10: the nearest config file applies) for client/vm/: the generated and vendored trees
// are not ours; the Node scripts get Node globals.
import js from '@eslint/js';
import globals from 'globals';

export default [
  { ignores: ['vendor/', 'pkg/', 'pkg-node/', 'tools/', 'runner/target/', 'fixtures/ball_drop/target/'] },
  js.configs.recommended,
  { languageOptions: { globals: { ...globals.node } } },
];
