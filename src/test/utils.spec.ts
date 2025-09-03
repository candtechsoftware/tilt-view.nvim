import * as a from 'node:assert/strict';
import * as test from 'node:test';
import { addMicrosecondOffsetToIsoDatetime } from '../utils';
import { ZodError } from 'zod';

test.suite('addMicrosecondOffsetToIsoDatetime', () => {
  test.test('Adds 3 digits to milliseconds: Date object', () => {
    const dt = addMicrosecondOffsetToIsoDatetime(
      new Date(2020, 1, 1, 1, 2, 3, 123),
    );
    a.equal(dt, '2020-02-01T01:02:03.123000Z');
  });

  test.test('Adds 3 digits to milliseconds: datetime string', () => {
    const dt = addMicrosecondOffsetToIsoDatetime('2020-02-01T01:02:03.123Z');
    a.equal(dt, '2020-02-01T01:02:03.123000Z');
  });

  test.test('Throws known error if given non-ISO datetime', () => {
    a.throws(
      () => addMicrosecondOffsetToIsoDatetime('02/01/2020'),
      (err) => err instanceof ZodError,
    );
  });

  test.test(
    'Throws known error if given ISO datetime that already has microsecond resolution',
    () => {
      a.throws(
        () => addMicrosecondOffsetToIsoDatetime('2020-02-01T01:02:03.123456Z'),
        (err) =>
          err instanceof Error &&
          err.message ===
            'Expected milliseconds of datetime to match "[0-9]{3}Z" but instead received 123456Z',
      );
    },
  );
});
