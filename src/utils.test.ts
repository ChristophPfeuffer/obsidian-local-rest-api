import { timingSafeEqualStrings } from "./utils";

describe("timingSafeEqualStrings", () => {
  test("returns true for identical strings", () => {
    expect(timingSafeEqualStrings("abc123", "abc123")).toBe(true);
  });

  test("returns false for a same-length mismatch", () => {
    expect(timingSafeEqualStrings("abc123", "abc124")).toBe(false);
  });

  test("returns false for a length mismatch, without throwing", () => {
    expect(timingSafeEqualStrings("short", "a-much-longer-value")).toBe(false);
    expect(timingSafeEqualStrings("a-much-longer-value", "short")).toBe(false);
  });

  test("returns false comparing against an empty string", () => {
    expect(timingSafeEqualStrings("abc123", "")).toBe(false);
  });

  test("returns true for two empty strings", () => {
    expect(timingSafeEqualStrings("", "")).toBe(true);
  });
});
