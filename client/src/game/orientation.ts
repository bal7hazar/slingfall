/**
 * Phones play in landscape (docs/briefs/m6b-phone-landscape.md): in portrait the page shows a "rotate your phone"
 * overlay and the scene waits. The query is evaluated here, once; `style.css` shows the overlay from the class this
 * module sets on `<body>`, never from its own media query, so the overlay and the pause cannot disagree.
 * The coarse pointer keeps a narrow desktop window (a mouse) out; 600 px is `main.ts`'s NARROW width.
 */
export const PHONE_PORTRAIT = '(orientation: portrait) and (max-width: 600px) and (pointer: coarse)';
/** The class on `<body>` while the overlay shows. */
export const OVERLAY_CLASS = 'rotate-phone';
/** Everything interactive but the overlay: the scene, the HUD and chain strip, the banner, the result panel, the controls. */
export const INERT_SELECTORS = ['#app', '.top', '#banner', '#result', '#controls'];

/** What the guard needs from `window.matchMedia(...)`. */
export interface MediaSource {
  matches: boolean;
  addEventListener(type: 'change', listener: () => void): void;
  removeEventListener(type: 'change', listener: () => void): void;
}

/** The playback's playing flag: the guard sets it directly, never `toggle()` (at the end of a finished trace it restarts from 0). */
export interface PlayingFlag {
  playing: boolean;
}

let shown = false;

/** Whether the overlay shows now: the key handlers (`AimController`) and `?autoshot` do nothing while it does. */
export function overlayShown(): boolean {
  return shown;
}

export class OrientationGuard {
  private readonly media: MediaSource;
  private readonly body: Pick<HTMLElement, 'classList'>;
  private readonly playback: PlayingFlag;
  private readonly inert: () => Iterable<Pick<HTMLElement, 'inert'>>;
  private readonly onChange: (shown: boolean) => void;
  /** The playing flag when the overlay appeared, restored when it goes. */
  private saved = false;

  constructor(options: {
    media: MediaSource;
    body: Pick<HTMLElement, 'classList'>;
    playback: PlayingFlag;
    /** The elements made inert while the overlay shows (the overlay itself is not one). */
    inert: () => Iterable<Pick<HTMLElement, 'inert'>>;
    onChange?: (shown: boolean) => void;
  }) {
    this.media = options.media;
    this.body = options.body;
    this.playback = options.playback;
    this.inert = options.inert;
    this.onChange = options.onChange ?? (() => {});
    this.media.addEventListener('change', this.update);
    this.update();
  }

  get shown(): boolean {
    return shown;
  }

  dispose(): void {
    this.media.removeEventListener('change', this.update);
    if (shown) this.hide(false);
  }

  /** A stage replaced the playback's state (`show()` sets playing) while the overlay shows: the new value is the one to restore. */
  adopt(): void {
    if (!shown) return;
    this.saved = this.playback.playing;
    this.playback.playing = false;
  }

  private readonly update = (): void => {
    if (this.media.matches === shown) return;
    if (this.media.matches) {
      this.saved = this.playback.playing;
      this.playback.playing = false;
      shown = true;
      this.body.classList.add(OVERLAY_CLASS);
      this.setInert(true);
      this.onChange(true);
    } else {
      this.hide(true);
    }
  };

  private hide(notify: boolean): void {
    shown = false;
    this.playback.playing = this.saved;
    this.body.classList.remove(OVERLAY_CLASS);
    this.setInert(false);
    if (notify) this.onChange(false);
  }

  private setInert(on: boolean): void {
    for (const element of this.inert()) element.inert = on;
  }
}

/** The guard of the page: `window.matchMedia` and the elements of `index.html`. */
export function pageGuard(playback: PlayingFlag, onChange?: (shown: boolean) => void): OrientationGuard {
  return new OrientationGuard({
    media: window.matchMedia(PHONE_PORTRAIT),
    body: document.body,
    playback,
    inert: () => INERT_SELECTORS.flatMap((selector) => [...document.querySelectorAll<HTMLElement>(selector)]),
    onChange,
  });
}
