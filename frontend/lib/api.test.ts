import { ApiError, apiFetch, setAccessToken, setRefreshHandler } from "./api";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

beforeEach(() => {
  setAccessToken(null);
  setRefreshHandler(null);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("apiFetch", () => {
  it("attaches the current access token as a Bearer header", async () => {
    setAccessToken("token-123");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    await apiFetch("/ping");

    const [, init] = fetchMock.mock.calls[0];
    expect((init.headers as Headers).get("Authorization")).toBe("Bearer token-123");
    // Also sent as X-Auth-Token - survives CloudFront OAC overwriting Authorization on the
    // streaming Lambda's Function URL origin path. See api.ts's rawFetch comment.
    expect((init.headers as Headers).get("X-Auth-Token")).toBe("token-123");
  });

  it("does not attach a token when auth is disabled", async () => {
    setAccessToken("token-123");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({}));
    vi.stubGlobal("fetch", fetchMock);

    await apiFetch("/public", {}, { auth: false });

    const [, init] = fetchMock.mock.calls[0];
    expect((init.headers as Headers).has("Authorization")).toBe(false);
  });

  it("retries exactly once, with the refreshed token, after a single 401", async () => {
    setAccessToken("stale-token");
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ detail: "expired" }, 401))
      .mockResolvedValueOnce(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    const refreshHandler = vi.fn().mockResolvedValue("fresh-token");
    setRefreshHandler(refreshHandler);

    const result = await apiFetch<{ ok: boolean }>("/protected");

    expect(refreshHandler).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect((fetchMock.mock.calls[1][1].headers as Headers).get("Authorization")).toBe(
      "Bearer fresh-token",
    );
    expect(result).toEqual({ ok: true });
  });

  it("does not retry a second time if the refreshed request also 401s", async () => {
    setAccessToken("stale-token");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ detail: "still invalid" }, 401));
    vi.stubGlobal("fetch", fetchMock);
    setRefreshHandler(vi.fn().mockResolvedValue("fresh-token"));

    await expect(apiFetch("/protected")).rejects.toThrow(ApiError);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("does not retry when the refresh handler itself fails to produce a token", async () => {
    setAccessToken("stale-token");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ detail: "expired" }, 401));
    vi.stubGlobal("fetch", fetchMock);
    setRefreshHandler(vi.fn().mockResolvedValue(null));

    await expect(apiFetch("/protected")).rejects.toThrow(ApiError);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("raises a typed ApiError carrying the server's detail message on non-2xx", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse({ detail: "Invalid email or password" }, 401));
    vi.stubGlobal("fetch", fetchMock);

    await expect(apiFetch("/auth/login", {}, { auth: false })).rejects.toMatchObject({
      message: "Invalid email or password",
      status: 401,
    });
  });

  it("raises a typed ApiError instead of an unhandled rejection on a network failure", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new TypeError("Failed to fetch"));
    vi.stubGlobal("fetch", fetchMock);

    await expect(apiFetch("/anything", {}, { auth: false })).rejects.toThrow(ApiError);
  });

  it("returns undefined for a 204 response", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await apiFetch("/auth/logout", { method: "POST" });
    expect(result).toBeUndefined();
  });
});
