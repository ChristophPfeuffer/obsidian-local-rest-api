import { timingSafeEqual } from "crypto";

/**
 * Compares two strings for equality without letting a mismatch's *position*
 * leak through response timing.
 *
 * `===` on a JS string short-circuits at the first differing character, so an
 * attacker who can measure response latency precisely enough (and send many
 * requests) can in principle recover a secret one character at a time rather
 * than needing to guess the whole thing at once — the actual danger of a
 * "timing attack" is that it can turn an otherwise-infeasible brute force
 * into a feasible one, not that guessing itself becomes possible.
 *
 * `crypto.timingSafeEqual` compares in constant time, but only for two
 * buffers of equal length — it throws otherwise, and a naive fallback to a
 * length check plus early return would just relocate the leak: now response
 * time reveals *whether the length matched*. Since the length in this
 * codebase's one caller (a fixed-format 64-character hex API key) isn't
 * actually the secret part, the fallback below does a constant-time compare
 * against a same-length buffer even when lengths differ, so a length
 * mismatch takes the same code path — and roughly the same time — as any
 * other mismatch, rather than returning early.
 */
export function timingSafeEqualStrings(a: string, b: string): boolean {
  const aBuf = Buffer.from(a, "utf8");
  const bBuf = Buffer.from(b, "utf8");
  if (aBuf.length !== bBuf.length) {
    timingSafeEqual(bBuf, bBuf);
    return false;
  }
  return timingSafeEqual(aBuf, bBuf);
}

export function toArrayBuffer(
  arr: Uint8Array | ArrayBuffer | DataView | object,
): ArrayBuffer {
  if (arr instanceof ArrayBuffer) {
    return arr;
  }

  if (arr instanceof Uint8Array || arr instanceof DataView) {
    const view =
      arr instanceof Uint8Array
        ? arr
        : new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength);

    if (view.buffer instanceof ArrayBuffer) {
      return view.buffer.slice(
        view.byteOffset,
        view.byteOffset + view.byteLength,
      );
    }

    const copy = new Uint8Array(view.byteLength);
    copy.set(view);
    return copy.buffer;
  }

  const encoder = new TextEncoder();
  return encoder.encode(JSON.stringify(arr)).buffer;
}
