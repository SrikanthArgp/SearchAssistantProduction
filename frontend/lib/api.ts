const API_BASE_URL = process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://localhost:8000/v1";

export class ApiError extends Error {
  status: number | null;
  body: unknown;

  constructor(message: string, status: number | null, body?: unknown) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

type RefreshHandler = () => Promise<string | null>;

let currentAccessToken: string | null = null;
let refreshHandler: RefreshHandler | null = null;

// AuthProvider is the only writer of these — kept module-level (not React state) so
// every apiFetch call site attaches the current token without needing a hook/prop.
export function setAccessToken(token: string | null): void {
  currentAccessToken = token;
}

export function setRefreshHandler(handler: RefreshHandler | null): void {
  refreshHandler = handler;
}

async function parseBodySafely(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function extractDetail(body: unknown, fallback: string): string {
  if (body && typeof body === "object" && "detail" in body) {
    const detail = (body as { detail?: unknown }).detail;
    if (typeof detail === "string") return detail;
  }
  return fallback;
}

async function rawFetch(path: string, init: RequestInit, token: string | null): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body !== undefined && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
    // Also sent as a custom header: CloudFront's Origin Access Control overwrites Authorization
    // with its own AWS SigV4 signature en route to the streaming Lambda's Function URL origin
    // (AWS_IAM auth), so this app's own bearer token can't survive in that header on that path —
    // only on this one. The buffered/API-Gateway path has no such conflict, but sending both
    // headers unconditionally means this doesn't need to special-case by route. See
    // backend/auth/dependencies.py's extract_bearer_token and infra/lambda-gate/cloudfront.tf's
    // OAC comments for the full story.
    headers.set("X-Auth-Token", token);
  }

  try {
    return await fetch(`${API_BASE_URL}${path}`, { ...init, headers });
  } catch {
    // fetch() only throws on network-level failure (DNS, connection refused, offline) —
    // never surface this as an unhandled rejection, always a typed error the UI can render.
    throw new ApiError("Network error — check your connection and try again.", null);
  }
}

export interface ApiFetchOptions {
  /** Attach the current access token and retry-after-refresh on 401. Default true. */
  auth?: boolean;
}

// Shared by apiFetch (JSON) and lib/sse.ts (raw streaming body) - both need the same
// Authorization-header-plus-single-refresh-then-retry-on-401 behavior, just different
// handling of the response body afterwards.
export async function fetchWithAuth(
  path: string,
  init: RequestInit = {},
  options: ApiFetchOptions = {},
): Promise<Response> {
  const useAuth = options.auth !== false;

  let response = await rawFetch(path, init, useAuth ? currentAccessToken : null);

  if (response.status === 401 && useAuth && refreshHandler) {
    const newToken = await refreshHandler();
    if (newToken) {
      response = await rawFetch(path, init, newToken);
    }
  }

  return response;
}

export async function apiFetch<T>(
  path: string,
  init: RequestInit = {},
  options: ApiFetchOptions = {},
): Promise<T> {
  const response = await fetchWithAuth(path, init, options);

  if (!response.ok) {
    const body = await parseBodySafely(response);
    throw new ApiError(
      extractDetail(body, `Request failed with status ${response.status}`),
      response.status,
      body,
    );
  }

  if (response.status === 204) return undefined as T;
  return (await parseBodySafely(response)) as T;
}
