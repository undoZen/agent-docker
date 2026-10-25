#!/usr/bin/env node
// 容器对外入口：0.0.0.0:$MIRASIM_FORWARD_PORT → 127.0.0.1:$MIRASIM_PORT（serve）。
//
// 取代原来的 socat。socat 只解决了「对端恒为回环」，解决不了 token：
// mirasim 前端只给 /ws 拼 ?token=，/api/*、/mirachannel/pair 一个都不带，
// 服务端又不读 cookie —— 于是浏览器里 /api/state 恒 401、pair 恒 403。
//
// 这里补上缺的那一环：
//   1. 请求带了 ?token= 或 cookie → 拿它去 serve 的 /api/state 实际问一次，
//      200 才算对（结果按 token 缓存几秒）。对了就补 x-mirasim-token 头再转给 serve，
//      带的是 ?token= 的还顺手种一个 HttpOnly cookie（打开 make url 那一下）。
//      不在本地跟 MIRASIM_LOCAL_TOKEN 比：serve 实际用哪把钥匙只有它自己说了算
//      （没设变量时它会随机一把），本地比对可能和 serve 对不上。
//   2. 直接带 x-mirasim-token / Authorization: Bearer 的客户端 → 原样转发，serve 自己验。
//   3. 都没有、或 token 被 serve 拒了 → 不转发，直接回 401 和一个说明页（告诉人去
//      make url 拿地址），免得浏览器里只看到一堆 /api/* 401、pair 403 而不知道是 cookie 丢了。
// 认证强度不变：没有 token 的人拿不到 cookie，也就什么都补不上。
"use strict";

const http = require("http");
const net = require("net");

const LISTEN_PORT = Number(process.env.MIRASIM_FORWARD_PORT || 4938);
const UPSTREAM_PORT = Number(process.env.MIRASIM_PORT || 4939);
const UPSTREAM_HOST = "127.0.0.1";
const COOKIE = "mirasim_local_token";

function cookieToken(header) {
  for (const part of (header || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === COOKIE) {
      try { return decodeURIComponent(part.slice(i + 1).trim()); } catch { return null; }
    }
  }
  return null;
}

// token → { ok, exp }。对的缓存 30 秒、错的 5 秒：网页一次加载会并发几十个请求，
// 不能每个都去问一次；又不能缓存太久，serve 换了钥匙要尽快反映出来。
const verified = new Map();
function verify(token) {
  const now = Date.now();
  const hit = verified.get(token);
  if (hit && hit.exp > now) return hit.ok;
  const p = new Promise((resolve) => {
    const r = http.get(
      { host: UPSTREAM_HOST, port: UPSTREAM_PORT, path: "/api/state",
        headers: { "x-mirasim-token": token }, timeout: 5000 },
      (res) => { res.resume(); resolve(res.statusCode === 200); }
    );
    r.on("timeout", () => r.destroy());
    r.on("error", () => resolve(false));
  });
  verified.set(token, { ok: p, exp: now + 30_000 });
  p.then((ok) => {
    if (verified.size > 256) verified.clear();
    verified.set(token, { ok: p, exp: Date.now() + (ok ? 30_000 : 5_000) });
  });
  return p;
}

// 返回 { ok, path, headers, setCookie }：是否放行、转给上游的路径和头，以及要种的 cookie。
// /ws 只认 ?token=（不看头），所以 Upgrade 请求在没带 token 时把它拼进 query。
async function authorize(req, { intoQuery = false } = {}) {
  const headers = { ...req.headers };
  if (headers["x-mirasim-token"] || /^Bearer\s/i.test(headers.authorization || "")) {
    return { ok: true, path: req.url, headers, setCookie: null };
  }

  let url = null;
  try { url = new URL(req.url, "http://x"); } catch {}
  const queryToken = (url && url.searchParams.get("token")) || null;
  const fromCookie = cookieToken(req.headers.cookie);

  let token = null;
  if (queryToken && await verify(queryToken)) token = queryToken;
  else if (fromCookie && await verify(fromCookie)) token = fromCookie;
  if (!token) return { ok: false };

  headers["x-mirasim-token"] = token;
  let path = req.url;
  if (intoQuery && url && !queryToken) {
    url.searchParams.set("token", token);
    path = url.pathname + url.search;
  }
  const setCookie = token !== fromCookie
    ? `${COOKIE}=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Strict`
    : null;
  return { ok: true, path, headers, setCookie };
}

const UNAUTHORIZED_PAGE = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>未授权 · Mirasim</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:36em;margin:15vh auto;padding:0 16px}code{background:#8882;padding:.1em .3em;border-radius:4px}</style>
</head><body>
<h1>401 未授权</h1>
<p>这个浏览器还没有登录凭据（cookie 不存在或已失效）。</p>
<p>在宿主机仓库目录执行 <code>make url</code>，用它打印出来的带 <code>?token=</code> 的地址打开一次即可。</p>
</body></html>
`;

const server = http.createServer(async (req, res) => {
  const { ok, path, headers, setCookie } = await authorize(req);
  if (!ok) {
    req.resume();
    res.writeHead(401, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(UNAUTHORIZED_PAGE);
    return;
  }
  const up = http.request(
    { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path, headers },
    (upRes) => {
      const out = { ...upRes.headers };
      if (setCookie) {
        const prev = out["set-cookie"] || [];
        out["set-cookie"] = [...(Array.isArray(prev) ? prev : [prev]), setCookie];
      }
      res.writeHead(upRes.statusCode, upRes.statusMessage, out);
      upRes.pipe(res);
    }
  );
  up.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("mirasim serve 不可达\n");
  });
  req.pipe(up);
});

// WebSocket（/ws）等 Upgrade 请求：补完头后直接接成双向裸 TCP
server.on("upgrade", async (req, sock, head) => {
  sock.on("error", () => sock.destroy());
  const { ok, path, headers } = await authorize(req, { intoQuery: true });
  if (!ok) {
    sock.end("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return;
  }
  const up = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    let raw = `${req.method} ${path} HTTP/${req.httpVersion}\r\n`;
    for (const [k, v] of Object.entries(headers)) {
      for (const one of Array.isArray(v) ? v : [v]) raw += `${k}: ${one}\r\n`;
    }
    up.write(raw + "\r\n");
    if (head && head.length) up.write(head);
    sock.pipe(up).pipe(sock);
  });
  const close = () => { sock.destroy(); up.destroy(); };
  up.on("error", close);
  sock.on("error", close);
});

server.keepAliveTimeout = 65_000;
server.listen({ port: LISTEN_PORT, host: "0.0.0.0", backlog: 511 }, () => {
  console.log(`→ 转发已启动：容器 :${LISTEN_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}（cookie 换 token，经 /api/state 校验）`);
});
