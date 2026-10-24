import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import worker from "../src/worker.js";

const latestURL = "https://github.com/funny-dog/inkpot/releases/latest";

test("下载始终跳转 latest，不调用 GitHub API", async (t) => {
  t.mock.method(globalThis, "fetch", () => { throw new Error("不应请求网络"); });
  const response = await worker.fetch(new Request("https://inkpot.example/download"), {});
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), latestURL);
});

test("下载支持配置仓库", async () => {
  const response = await worker.fetch(new Request("https://inkpot.example/download"), { GITHUB_REPO: "owner/app" });
  assert.equal(response.headers.get("Location"), "https://github.com/owner/app/releases/latest");
});

test("版本接口提供页面使用的体积摘要", async (t) => {
  t.mock.method(globalThis, "fetch", async () => Response.json({
    tag_name: "v1.0.0",
    published_at: "2026-10-24T00:00:00Z",
    assets: [{ name: "Inkpot.dmg", size: 123456, browser_download_url: "https://github.com/funny-dog/inkpot/releases/download/v1.0.0/Inkpot.dmg" }],
  }));
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  t.after(() => { delete globalThis.caches; });
  const response = await worker.fetch(new Request("https://inkpot.example/api/release"), {});
  const data = await response.json();
  assert.equal(response.status, 200);
  assert.equal(data.asset_size, 123456);
  assert.equal(data.tag_name, "v1.0.0");
});

test("私有仓库或暂无发布时版本接口明确失败", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response(null, { status: 404 }));
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  t.after(() => { delete globalThis.caches; });
  const response = await worker.fetch(new Request("https://inkpot.example/api/release"), {});
  assert.equal(response.status, 502);
});

test("首页全部下载按钮直达 latest", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.equal(html.match(new RegExp(`href="${latestURL}"`, "g"))?.length, 3);
  assert.ok(!html.includes('href="/download"'));
});
