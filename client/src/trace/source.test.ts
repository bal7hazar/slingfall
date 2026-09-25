import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { RecordedTraceSource, parseTrace } from './source';
import { fixedToNumber, type TraceFrame } from './types';

const readFixture = async (url: string) =>
  JSON.parse(await readFile(new URL(`../../public${url}`, import.meta.url), 'utf8'));

describe('RecordedTraceSource', () => {
  it('yields the frames of a recorded trace in tick order', async () => {
    const source = new RecordedTraceSource('/traces/sample.json', readFixture);
    const frames: TraceFrame[] = [];
    for await (const frame of source.frames()) frames.push(frame);

    expect(source.kind).toBe('recorded');
    expect(frames.map((f) => f.tick)).toEqual([0, 1, 2]);
    expect(fixedToNumber(frames[0].bodies[0].y)).toBe(5);
  });

  it('rejects a document that is not a trace', () => {
    expect(() => parseTrace({ frames: 3 })).toThrow('not a trace');
  });
});
