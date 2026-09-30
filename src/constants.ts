import { ErrorCode, LocalRestApiSettings } from "./types";

export const CERT_NAME = "obsidian-local-rest-api.crt";

export const BUILT_IN_ROUTES = ["/", "/openapi.yaml", `/${CERT_NAME}`];

/**
 * The MCP protocol revision served by the `/mcp/` endpoint's sessionless leg.
 *
 * The SDK's `SUPPORTED_PROTOCOL_VERSIONS` lists only the sessionful revisions
 * (2024-10-07 through 2025-11-25) and exports no constant for this one, so it is named
 * here: the `MCP-Protocol-Version` header filter accepts both sets.
 */
export const MCP_SESSIONLESS_PROTOCOL_VERSION = "2026-07-28";

/**
 * Failed-authentication throttling. Deliberately global rather than keyed by
 * source IP or any other client-supplied identifier: IP is trivial to rotate
 * (a new client instance, a VPN hop, DHCP renewal) and nothing about a
 * request reliably identifies the *machine* behind it — a MAC address isn't
 * visible past the local network segment even when the client is on the same
 * LAN, and modern OSes randomize it per network by default anyway. A global
 * counter can't be sidestepped by changing who you appear to be, at the cost
 * of one shared failure budget for every legitimate client too — acceptable
 * here because the actual defense against brute force is the 256-bit random
 * key (see LocalRestApi.onload's key generation), not this throttle. This
 * only raises the cost of noisy, automated guessing and gives the access log
 * something to show for it; it is not, on its own, a strong barrier.
 */
export const AUTH_FAILURE_WINDOW_MS = 60_000;
export const AUTH_FAILURE_DELAY_THRESHOLD = 5;
export const AUTH_FAILURE_DELAY_STEP_MS = 50;
export const AUTH_FAILURE_MAX_DELAY_MS = 2000;

/**
 * How long a REST request (routes wrapped by `RequestHandler.handle()`) is
 * allowed to wait for a response before this server gives up and answers 503
 * itself, rather than leaving the connection open indefinitely. See
 * `handle()`'s own doc comment for what this can and cannot fix.
 *
 * Ordinary vault reads/writes are sub-second on local disk, so 5s is already
 * generous by that measure -- but the one realistic case that measure
 * doesn't account for is a vault living on a cloud-sync client (iCloud
 * Drive, Nextcloud, Dropbox, OneDrive): a write can legitimately block for a
 * few seconds waiting on that client's own lock or flush, independent of any
 * bug here. 5s leaves some room for that without coming anywhere near what
 * "hanging forever" looked like before this existed. If this value turns
 * out to produce false-positive 503s on a particular setup, it is safe to
 * raise -- it trades a slower failure report for fewer false alarms, not
 * correctness either way.
 */
export const REQUEST_TIMEOUT_MS = 5_000;

export const DEFAULT_SETTINGS: LocalRestApiSettings = {
  port: 27124,
  insecurePort: 27123,
  enableInsecureServer: false,
};

export const ERROR_CODE_MESSAGES: Record<ErrorCode, string> = {
  [ErrorCode.InvalidFrontmatter]:
    "Document frontmatter could not be parsed.",
  [ErrorCode.ApiKeyAuthorizationRequired]:
    "Authorization required.  Find your API Key in the 'Local REST API with MCP' section of your Obsidian settings.",
  [ErrorCode.ContentTypeSpecificationRequired]:
    "Content-Type header required; this API accepts data in multiple content-types and you must indicate the content-type of your request body via the Content-Type header.",
  [ErrorCode.InvalidContentType]:
    "Unknown or invalid Content-Type specified in Content-Type header.",
  [ErrorCode.InvalidContentForContentType]:
    "Your request body could not be processed as the content-type specified in your Content-Type header.",
  [ErrorCode.RequestMethodValidOnlyForFiles]:
    "Request method is valid only for file paths, not directories.",
  [ErrorCode.TextContentEncodingRequired]:
    "Incoming content must be text data and have an appropriate text/* Content-type header set (e.g. text/markdown).",
  [ErrorCode.InvalidFilterQuery]:
    "The query you provided could not be processed.",
  [ErrorCode.MissingTargetTypeHeader]: "No 'Target-Type' header was provided.",
  // A target type or scope can arrive by header *or* by URL path element, so
  // these read neutrally; the call site appends where the bad value came from
  // and which values are valid there (the two patch formats accept different
  // scopes). getResponseMessage prepends this text to any custom message, so a
  // call site that restates what is already here produces a doubled response.
  [ErrorCode.InvalidTargetTypeHeader]:
    "The target type you specified was invalid. Valid target types are 'heading', 'block', and 'frontmatter'.",
  [ErrorCode.MissingTargetHeader]: "No 'Target' header was provided.",
  [ErrorCode.InvalidTargetScopeHeader]:
    "The target scope you specified was invalid.",
  [ErrorCode.MissingOperation]: "No 'Operation' header was provided.",
  [ErrorCode.InvalidOperation]:
    "The 'Operation' header you provided was invalid.",
  [ErrorCode.InvalidTargetHeader]: "The 'Target' header you provided was invalid.",
  [ErrorCode.InvalidPatchVersionHeader]:
    "The 'Markdown-Patch-Version' header you provided was invalid. Valid values are '1' (the deprecated header-driven format) and '2' (the default JSON-instruction format).",
  [ErrorCode.HeaderTargetingRequiresVersion1]:
    "Header-based targeting (Target-Type/Target and the related Target-Scope/Target-Delimiter/Trim-Target-Whitespace headers) is deprecated and only processed when you also send 'Markdown-Patch-Version: 1'. Without it, reach a sub-part of a document with path-element targeting instead (e.g. /vault/note.md/heading/My%20Heading).",
  [ErrorCode.PatchHeaderTargetingRequiresExplicitVersion]:
    "Header-based PATCH targeting is ambiguous between the two patch formats, so it requires an explicit 'Markdown-Patch-Version' header: send '1' for the deprecated 1.x header-driven format, or '2' for raw-content mode (instruction fields in headers — heading Targets as percent-encoded JSON arrays — with the raw payload as the request body). The 1.x-only Target-Delimiter and Trim-Target-Whitespace headers are never processed under version 2.",
  [ErrorCode.PatchFailed]:
    "The patch you provided could not be applied to the target content.",
  [ErrorCode.InvalidPatchInstruction]:
    "The patch instruction you provided was malformed or outside the supported algebra.",
  [ErrorCode.InvalidSearch]: "The search query you provided is not valid.",
  [ErrorCode.ConflictingTargetSpecification]:
    "Conflicting target specifications: supply the target via URL path elements, via Target-Type/Target headers, or (for PATCH) as an 'application/vnd.olrapi.patch-instruction+json' instruction body — never more than one of these.",
  [ErrorCode.ErrorPreparingSimpleSearch]:
    "Error encountered while calling Obsidian `prepareSimpleSearch` API.",
  [ErrorCode.MissingDestinationHeader]:
    "Destination header is required for MOVE and COPY operations.",
  [ErrorCode.InvalidDestinationHeader]:
    "The 'Destination' header you provided could not be parsed.",
  [ErrorCode.InvalidWithinHeader]:
    "The 'Within' header must be a single integer, e.g. 0 or -1.",
  [ErrorCode.PathTraversalNotAllowed]:
    "Path traversal is not allowed. Paths must be relative and within the vault.",
  [ErrorCode.DestinationAlreadyExists]:
    "Destination file already exists.",
  [ErrorCode.FileOperationFailed]:
    "File operation failed. Check the error message for details.",
};

export enum ContentTypes {
  json = "application/json",
  markdown = "text/markdown",
  html = "text/html",
  olrapiNoteJson = "application/vnd.olrapi.note+json",
  olrapiDocumentMap = "application/vnd.olrapi.document-map+json",
  olrapiPatchInstruction = "application/vnd.olrapi.patch-instruction+json",
  jsonLogic = "application/vnd.olrapi.jsonlogic+json",
}

export const DefaultBearerTokenHeaderName = "Authorization";
export const DefaultBindingHost = "127.0.0.1";

export const LicenseUrl =
  "https://raw.githubusercontent.com/coddingtonbear/obsidian-local-rest-api/main/LICENSE";

export const MaximumRequestSize = "1024mb";

// Ceiling on the bytes `vault_read_binary` and `vault_write_binary` will carry. This is a
// context guard, not a storage limit: base64 in a tool argument or result passes through
// the model's context at roughly 0.35-0.45 tokens per byte, so a file a REST client would
// not think twice about is a five-figure token bill for an agent. Anything larger belongs
// on `GET`/`PUT /vault/<path>`, which carry raw bytes and are bounded only by
// `MaximumRequestSize` above.
export const MaximumMcpBinaryBytes = 1024 * 1024;
