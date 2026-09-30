import http from "http";
import type { AddressInfo } from "net";

import { closeServer, describeServerError } from "./serverLifecycle";

function listen(server: http.Server, port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("listening", () => {
      server.removeListener("error", reject);
      resolve();
    });
    server.once("error", reject);
    server.listen(port, "127.0.0.1");
  });
}

describe("closeServer", () => {
  test("resolves immediately for a null server", async () => {
    await expect(closeServer(null)).resolves.toBeUndefined();
  });

  test("waits for a real server to finish closing", async () => {
    const server = http.createServer();
    await listen(server, 0);

    await closeServer(server);

    expect(server.listening).toBe(false);
  });
});

// This is the scenario the fix is actually about: two real servers, bound to
// a real port, on the real OS network stack -- not a mock. Before the fix,
// neither server had an "error" listener, so the bind failure below would
// have been an uncaught exception (an EventEmitter's "error" event with no
// listener throws) instead of the caught, reported event these tests
// observe.
describe("binding two servers to the same port", () => {
  test("the second bind fails with a caught, descriptive EADDRINUSE -- not an uncaught throw", async () => {
    const first = http.createServer();
    await listen(first, 0);
    const port = (first.address() as AddressInfo).port;

    const second = http.createServer();
    const errorEvent = new Promise<NodeJS.ErrnoException>((resolve) => {
      second.once("error", resolve);
    });
    second.listen(port, "127.0.0.1");

    // If this rejects, the "error" event above is not what fired -- e.g. the
    // bind unexpectedly succeeded, or the process crashed first (which jest
    // would in any case report as a suite-level failure, not a clean one).
    const error = await errorEvent;

    expect(error.code).toBe("EADDRINUSE");
    expect(describeServerError(port, error)).toBe(
      `port ${port} is already in use by another application`,
    );

    await closeServer(first);
  });

  test(
    "closeServer lets the same port be rebound immediately after -- the race " +
      "_refreshServerState used to lose by recreating a server before the old " +
      "one had actually released its port",
    async () => {
      const first = http.createServer();
      await listen(first, 0);
      const port = (first.address() as AddressInfo).port;

      await closeServer(first);

      const second = http.createServer();
      await listen(second, port);

      expect(second.listening).toBe(true);
      await closeServer(second);
    },
  );
});

describe("describeServerError", () => {
  test("names the responsible port for EADDRINUSE", () => {
    const error: NodeJS.ErrnoException = Object.assign(new Error("x"), {
      code: "EADDRINUSE",
    });
    expect(describeServerError(27124, error)).toBe(
      "port 27124 is already in use by another application",
    );
  });

  test("explains EACCES as a privilege issue rather than repeating the raw errno text", () => {
    const error: NodeJS.ErrnoException = Object.assign(new Error("permission denied"), {
      code: "EACCES",
    });
    expect(describeServerError(80, error)).toBe(
      "port 80 requires elevated privileges on this system",
    );
  });

  test("falls back to the raw error message for anything else (e.g. bad certificate material)", () => {
    const error: NodeJS.ErrnoException = new Error("unsupported PEM format");
    expect(describeServerError(27124, error)).toBe("unsupported PEM format");
  });
});
