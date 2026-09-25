import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';
import { SpikeTickLineParser } from './lines';
import { RecordedTraceSource, parseTrace } from './source';
import { fixedToNumber, type TraceFrame } from './types';

const readFixture = async (url: string): Promise<unknown> =>
  JSON.parse(await readFile(new URL(`../../public${url}`, import.meta.url), 'utf8'));

const PILE10 = '/traces/pile10.json';

describe('RecordedTraceSource', () => {
  it('yields the level, then the frames of a recorded trace in tick order', async () => {
    const source = new RecordedTraceSource(PILE10, readFixture);
    const level = await source.level();
    const frames: TraceFrame[] = [];
    for await (const frame of source.frames()) frames.push(frame);

    expect(source.kind).toBe('recorded');
    expect(level.bodies).toHaveLength(11);
    expect(frames.length).toBeGreaterThanOrEqual(120);
    expect(frames.map((f) => f.tick)).toEqual(frames.map((_, i) => i));
    expect(fixedToNumber(level.sling_anchor.y)).toBe(2.5);
  });

  it('exposes the events once the trace is loaded', async () => {
    const source = new RecordedTraceSource(PILE10, readFixture);
    expect(source.events).toEqual([]);
    await source.level();
    expect(source.events.map((e) => e.kind)).toContain('shot_end');
  });

  it('loads the document once for level() and frames()', async () => {
    let loads = 0;
    const source = new RecordedTraceSource(PILE10, async (url) => {
      loads++;
      return readFixture(url);
    });
    await source.level();
    for await (const frame of source.frames()) void frame;
    expect(loads).toBe(1);
  });
});

describe('parseTrace', () => {
  it('rejects a document that is not a trace', () => {
    expect(() => parseTrace({ frames: 3 })).toThrow('not a trace');
    expect(() => parseTrace(null)).toThrow('not a trace: document must be an object');
  });

  it('rejects an unknown version', async () => {
    const doc = { ...((await readFixture(PILE10)) as object), version: 2 };
    expect(() => parseTrace(doc)).toThrow('not a trace: version must be 1');
  });

  it('rejects a scalar that is not a decimal string within i64', async () => {
    const doc = (await readFixture(PILE10)) as { frames: { bodies: { x: unknown }[] }[] };
    doc.frames[3].bodies[0].x = 1.5;
    expect(() => parseTrace(doc)).toThrow('frames[3].bodies[0].x must be a decimal string');
    doc.frames[3].bodies[0].x = '9223372036854775808';
    expect(() => parseTrace(doc)).toThrow('within the i64 range');
  });

  it('rejects ticks that do not increase', async () => {
    const doc = (await readFixture(PILE10)) as { frames: { tick: number }[] };
    doc.frames[5].tick = 2;
    expect(() => parseTrace(doc)).toThrow('frames[5].tick must be greater than the previous tick');
  });
});

describe('SpikeTickLineParser', () => {
  const parser = new SpikeTickLineParser();

  it('reads the `tick <i> y <raw>` line of the spike', () => {
    expect(parser.parse('tick 12 y -21439053314')).toEqual({ tick: 12, y: '-21439053314' });
  });

  it('ignores every other line', () => {
    expect(parser.parse('score 100')).toBeNull();
    expect(parser.parse('tick 3')).toBeNull();
  });
});
