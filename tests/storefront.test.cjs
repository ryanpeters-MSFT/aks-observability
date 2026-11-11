const assert = require("node:assert/strict");
const { test } = require("node:test");

const baseUrl = process.env.STOREFRONT_URL;
if (!baseUrl) {
  throw new Error("Set STOREFRONT_URL to the storefront Gateway URL before running these tests");
}

test("gateway serves the storefront and its scenario controls", async () => {
  const response = await fetch(baseUrl, { signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Trace &amp; Tell Storefront/);
  for (const scenario of ["success", "slow", "failure", "exception", "retry", "invalid"]) {
    assert.ok(html.includes(`data-scenario="${scenario}"`));
  }
});

test("checkout scenarios return the expected outcomes and injected trace IDs", async (t) => {
  for (const [scenario, status] of [
    ["success", 200], ["slow", 200], ["failure", 503],
    ["exception", 500], ["retry", 200], ["invalid", 400]
  ]) {
    await t.test(scenario, async () => {
      const start = performance.now();
      const response = await fetch(new URL("/api/checkout", baseUrl), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ productId: "mug", quantity: 2, scenario }),
        signal: AbortSignal.timeout(10000)
      });
      const result = await response.json();
      assert.equal(response.status, status, JSON.stringify(result));
      assert.match(result.traceId, /^[0-9a-f]{32}$/);
      assert.notEqual(result.traceId, "0".repeat(32), "OTel injection must provide a real trace");
      if (status === 200) {
        assert.equal(result.product, "Observability mug");
        assert.equal(result.quantity, 2);
        assert.equal(result.total, 36);
        assert.equal(result.attempts, scenario === "retry" ? 2 : 1);
        assert.equal(response.headers.get("x-trace-id"), result.traceId);
      } else {
        assert.equal(result.service, "storefront");
        assert.ok(result.error);
      }
      if (scenario === "slow") {
        assert.ok(performance.now() - start >= 1400, "Slow inventory must produce measurable latency");
      }
    });
  }
});

test("invalid inputs are rejected rather than sent to inventory", async (t) => {
  for (const body of [
    { productId: "mug", quantity: 0 },
    { productId: "mug", quantity: 11 },
    { productId: "mug", quantity: 1.5 },
    { productId: "unknown", quantity: 1 },
    { productId: "mug", quantity: 1, scenario: "unknown" }
  ]) {
    await t.test(JSON.stringify(body), async () => {
      const response = await fetch(new URL("/api/checkout", baseUrl), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000)
      });
      assert.equal(response.status, 400);
      assert.match((await response.json()).error, /known product/);
    });
  }
});
