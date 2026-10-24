# Inkpot 官站

部署在 Cloudflare Workers 上的单页官网：静态资源 + 一个轻量 Worker。

## 结构

- `public/`：静态站点（首页、404、样式、脚本、应用图标）。
- `src/worker.js`：处理 `public/` 之外的路径——
  - `/download`：302 跳转到 GitHub Releases 的 `latest` 页面，与首页下载按钮一致，不依赖 GitHub API。
  - `/api/release`：转发 GitHub Latest Release 摘要（版本、日期、体积），供页面展示，边缘缓存 10 分钟。
- `wrangler.jsonc`：Workers 配置，`GITHUB_REPO` 变量指定源仓库。

## 本地开发与部署

```bash
cd website
npm install
npm run dev      # http://localhost:8787
npm test         # 离线检查下载跳转、版本摘要与页面链接
npm run deploy   # 部署到 Cloudflare Workers
```

需要 `wrangler login`（或 `CLOUDFLARE_API_TOKEN`）。

## 注意

下载统一指向 https://github.com/funny-dog/inkpot/releases/latest，由用户选择 DMG／ZIP 及同版本校验文件。仓库私有时需要有访问权限的 GitHub 账号；公开且发布正式 Release 后，匿名下载才可用。草稿和预发布版本不会成为 `latest`。

版本摘要接口依赖 GitHub API 的匿名访问；仓库私有、暂无正式 Release 或接口不可用时，页面隐藏版本信息，下载入口仍保留。
