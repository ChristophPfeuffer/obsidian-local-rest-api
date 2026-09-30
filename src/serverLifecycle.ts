import type http from "http";
import type https from "https";

/**
 * Waits for a server to fully stop accepting/serving connections before its
 * port can be safely reused. Never rejects -- the caller's only use for this
 * is "is the port free yet", not error reporting.
 *
 * This matters because `_refreshServerState` tears down and immediately
 * recreates a server bound to the same port on every settings change. Firing
 * `.close()` without waiting for it loses a race against the OS actually
 * releasing the socket: the new `.listen()` call can then fail with the same
 * `EADDRINUSE` a genuine external port conflict would produce, just
 * self-inflicted and intermittent -- see serverLifecycle.test.ts, which
 * reproduces both the external conflict and this self-inflicted race against
 * real bound ports.
 */
export function closeServer(server: http.Server | https.Server | null): Promise<void> {
  return new Promise((resolve) => {
    if (!server) {
      resolve();
      return;
    }
    server.closeAllConnections();
    server.close(() => resolve());
  });
}

/**
 * Turns a server's bind failure into a message worth showing a person,
 * naming the two failure modes actually worth distinguishing (a busy port,
 * an unprivileged port) and falling back to the raw message for anything
 * else (e.g. malformed certificate material, surfaced the same way even
 * though it is not a bind failure at all).
 */
export function describeServerError(port: number | undefined, error: NodeJS.ErrnoException): string {
  if (error.code === "EADDRINUSE") {
    return `port ${port} is already in use by another application`;
  }
  if (error.code === "EACCES") {
    return `port ${port} requires elevated privileges on this system`;
  }
  return error.message;
}
