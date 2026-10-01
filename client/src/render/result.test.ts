// @vitest-environment happy-dom
// The result panel's fold, and the stylesheet rule that keeps `hidden` elements hidden (lot L3).
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { foldResult, toggleResult } from './result';

describe('foldResult', () => {
  it('folds and opens, with the label and aria-expanded of the toggle', () => {
    const result = document.createElement('div');
    const toggle = document.createElement('button');
    foldResult(result, toggle, true);
    expect(result.classList.contains('folded')).toBe(true);
    expect([toggle.textContent, toggle.getAttribute('aria-expanded')]).toEqual(['Details', 'false']);
    toggleResult(result, toggle);
    expect(result.classList.contains('folded')).toBe(false);
    expect([toggle.textContent, toggle.getAttribute('aria-expanded')]).toEqual(['Hide', 'true']);
    toggleResult(result, toggle);
    expect(result.classList.contains('folded')).toBe(true);
  });
});

describe('style.css', () => {
  const css = readFileSync('src/style.css', 'utf8');

  it('keeps the hidden attribute stronger than an author display (the tier buttons of the local mode)', () => {
    expect(css).toMatch(/\[hidden\]\s*\{\s*display:\s*none\s*!important;/);
  });
});
