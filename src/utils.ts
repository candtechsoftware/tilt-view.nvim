import z from 'zod';

export const addMicrosecondOffsetToIsoDatetime = (
  input: string | Date,
): string => {
  let dtString: string;
  if (input instanceof Date) {
    dtString = input.toISOString();
  } else {
    dtString = z.iso.datetime().parse(input);
  }

  const [dtDateTime, dtMillis] = dtString.split('.');
  // Expected: 'nnnZ'
  if (!dtMillis.match(/^[0-9]{3}Z$/)) {
    throw new Error(
      `Expected milliseconds of datetime to match "[0-9]{3}Z" but instead received ${dtMillis}`,
    );
  }
  // Expected: nnn
  const dtMillisNum = `${dtMillis.slice(0, -1)}000`;
  return `${dtDateTime}.${dtMillisNum}Z`;
};
