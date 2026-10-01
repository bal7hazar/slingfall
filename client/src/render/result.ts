// The end-of-level panel's fold: title, summary and buttons stay, the outputs table and the Submit
// step hide. Folded at first on every screen: open on a desktop viewport the panel covers half of
// the board (lot L2, 1280x800), and the player wants to see the last shot first.
export function foldResult(result: HTMLElement, toggle: HTMLButtonElement, folded: boolean): void {
  result.classList.toggle('folded', folded);
  toggle.textContent = folded ? 'Details' : 'Hide';
  toggle.setAttribute('aria-expanded', String(!folded));
}

/** The toggle button: folds an open panel, opens a folded one. */
export function toggleResult(result: HTMLElement, toggle: HTMLButtonElement): void {
  foldResult(result, toggle, !result.classList.contains('folded'));
}
