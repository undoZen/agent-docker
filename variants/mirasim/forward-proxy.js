#!/usr/bin/env node
// 容器对外入口：0.0.0.0:$MIRASIM_FORWARD_PORT → 127.0.0.1:$MIRASIM_PORT（serve）。
//
// 取代原来的 socat。socat 只解决了「对端恒为回环」，解决不了 token：
// mirasim 前端只给 /ws 拼 ?token=，/api/*、/mirachannel/pair 一个都不带，
// 服务端又不读 cookie —— 于是浏览器里 /api/state 恒 401、pair 恒 403。
//
// 这里补上缺的那一环：
//   1. 请求带了正确的 ?token= → 种一个 HttpOnly cookie（打开 make url 那一下）
//   2. 之后带这个 cookie 的请求 → 自动补 x-mirasim-token 头再转给 serve
//   3. 两者都没有 → 原样转发，由 serve 自己拒绝
// 认证强度不变：没有 token 的人拿不到 cookie，也就什么都补不上。
"use strict";

const http = require("http");
const net = require("net");
const crypto = require("crypto");

const LISTEN_PORT = Number(process.env.MIRASIM_FORWARD_PORT || 4938);
const UPSTREAM_PORT = Number(process.env.MIRASIM_PORT || 4939);
const UPSTREAM_HOST = "127.0.0.1";
const TOKEN = (process.env.MIRASIM_LOCAL_TOKEN || "").trim();
const COOKIE = "mirasim_local_token";

function same(a, b) {
  if (!a || !b) return false;
  const x = Buffer.from(a), y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function cookieToken(header) {
  for (const part of (header || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === COOKIE) {
      try { return decodeURIComponent(part.slice(i + 1).trim()); } catch { return null; }
    }
  }
  return null;
}

// 返回 { path, headers, setCookie }：转给上游的路径和头，以及是否需要给浏览器种 cookie。
// /ws 只认 ?token=（不看头），所以 Upgrade 请求在没带 token 时把它拼进 query。
function authorize(req, { intoQuery = false } = {}) {
  const headers = { ...req.headers };
  if (!TOKEN) return { path: req.url, headers, setCookie: false };

  let url = null;
  try { url = new URL(req.url, "http://x"); } catch {}
  const queryToken = url ? url.searchParams.get("token") : null;
  const viaQuery = same(queryToken, TOKEN);
  const viaCookie = same(cookieToken(req.headers.cookie), TOKEN);

  let path = req.url;
  if (viaQuery || viaCookie) {
    if (!headers["x-mirasim-token"]) headers["x-mirasim-token"] = TOKEN;
    if (intoQuery && url && !queryToken) {
      url.searchParams.set("token", TOKEN);
      path = url.pathname + url.search;
    }
  }
  return { path, headers, setCookie: viaQuery && !viaCookie };
}

const setCookieValue =
  `${COOKIE}=${encodeURIComponent(TOKEN)}; Path=/; HttpOnly; SameSite=Strict`;

const server = http.createServer((req, res) => {
  const { path, headers, setCookie } = authorize(req);
  const up = http.request(
    { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path, headers },
    (upRes) => {
      const out = { ...upRes.headers };
      if (setCookie) {
        const prev = out["set-cookie"] || [];
        out["set-cookie"] = [...(Array.isArray(prev) ? prev : [prev]), setCookieValue];
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
server.on("upgrade", (req, sock, head) => {
  const { path, headers } = authorize(req, { intoQuery: true });
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
  console.log(`→ 转发已启动：容器 :${LISTEN_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}` +
    (TOKEN ? "（cookie 换 token）" : "（没有 MIRASIM_LOCAL_TOKEN，只做透传）"));
});
