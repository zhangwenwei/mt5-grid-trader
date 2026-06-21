/**
 * MAMETO COFFEE — オンライン注文サーバー
 * 依存ゼロ（Node 標準 http モジュールのみ）。
 *   node server.js          # http://localhost:3000
 *   PORT=8080 node server.js
 *
 * API:
 *   GET    /api/menu              メニュー取得
 *   GET    /api/orders           注文一覧（管理用）
 *   POST   /api/orders           注文作成
 *   PATCH  /api/orders/:id        注文ステータス更新 {status}
 */
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = process.env.PORT || 3000;
const ROOT = __dirname;
const PUBLIC = path.join(ROOT, "public");
const DATA = path.join(ROOT, "data");
const MENU_FILE = path.join(DATA, "menu.json");
const ORDERS_FILE = path.join(DATA, "orders.json");

const ORDER_STATUSES = ["received", "preparing", "ready", "completed", "cancelled"];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon",
  ".webmanifest": "application/manifest+json",
};

// ---- データ読み書き --------------------------------------------------------
function readMenu() {
  return JSON.parse(fs.readFileSync(MENU_FILE, "utf8"));
}
function readOrders() {
  try {
    return JSON.parse(fs.readFileSync(ORDERS_FILE, "utf8"));
  } catch {
    return [];
  }
}
function writeOrders(orders) {
  fs.writeFileSync(ORDERS_FILE, JSON.stringify(orders, null, 2));
}

// ---- レスポンスヘルパ ------------------------------------------------------
function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > 1e6) {
        reject(new Error("payload too large"));
        req.destroy();
        return;
      }
      data += c;
    });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

// ---- 注文バリデーション ----------------------------------------------------
function buildOrder(payload, menu) {
  const priceMap = {};
  const nameMap = {};
  for (const cat of menu.categories) {
    for (const it of cat.items) {
      priceMap[it.id] = it.price;
      nameMap[it.id] = it.name;
    }
  }

  if (!payload || !Array.isArray(payload.items) || payload.items.length === 0) {
    throw new Error("カートが空です。");
  }
  const name = String(payload.customerName || "").trim();
  if (!name) throw new Error("お名前を入力してください。");
  const phone = String(payload.phone || "").trim();

  const items = [];
  let total = 0;
  for (const line of payload.items) {
    const id = String(line.id || "");
    const qty = Math.max(1, Math.min(20, parseInt(line.qty, 10) || 0));
    if (!(id in priceMap)) throw new Error("不明な商品が含まれています: " + id);
    const price = priceMap[id];
    items.push({ id, name: nameMap[id], price, qty, subtotal: price * qty });
    total += price * qty;
  }

  const pickupTime = String(payload.pickupTime || "asap").trim();
  const note = String(payload.note || "").slice(0, 500);

  return {
    id: genId(),
    number: 0, // 採番は保存時
    customerName: name,
    phone,
    pickupTime,
    note,
    items,
    total,
    status: "received",
    createdAt: new Date().toISOString(),
  };
}

function genId() {
  return (
    Date.now().toString(36) + Math.random().toString(36).slice(2, 7)
  ).toUpperCase();
}

// ---- ルーティング ----------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = decodeURIComponent(url.pathname);

  try {
    // --- API ---
    if (pathname === "/api/menu" && req.method === "GET") {
      return sendJSON(res, 200, readMenu());
    }

    if (pathname === "/api/orders" && req.method === "GET") {
      return sendJSON(res, 200, readOrders());
    }

    if (pathname === "/api/orders" && req.method === "POST") {
      const raw = await readBody(req);
      let payload;
      try {
        payload = JSON.parse(raw || "{}");
      } catch {
        return sendJSON(res, 400, { error: "リクエストが不正です。" });
      }
      let order;
      try {
        order = buildOrder(payload, readMenu());
      } catch (e) {
        return sendJSON(res, 400, { error: e.message });
      }
      const orders = readOrders();
      order.number = (orders.reduce((m, o) => Math.max(m, o.number || 0), 0) || 100) + 1;
      orders.push(order);
      writeOrders(orders);
      console.log(
        `[注文] #${order.number} ${order.customerName} 様 — ¥${order.total} (${order.items.length}品)`
      );
      return sendJSON(res, 201, { ok: true, order });
    }

    const patchMatch = pathname.match(/^\/api\/orders\/([A-Z0-9]+)$/);
    if (patchMatch && req.method === "PATCH") {
      const id = patchMatch[1];
      const raw = await readBody(req);
      let payload = {};
      try {
        payload = JSON.parse(raw || "{}");
      } catch {}
      const status = String(payload.status || "");
      if (!ORDER_STATUSES.includes(status)) {
        return sendJSON(res, 400, { error: "不明なステータスです。" });
      }
      const orders = readOrders();
      const o = orders.find((x) => x.id === id);
      if (!o) return sendJSON(res, 404, { error: "注文が見つかりません。" });
      o.status = status;
      o.updatedAt = new Date().toISOString();
      writeOrders(orders);
      return sendJSON(res, 200, { ok: true, order: o });
    }

    if (pathname.startsWith("/api/")) {
      return sendJSON(res, 404, { error: "not found" });
    }

    // --- 静的ファイル ---
    return serveStatic(pathname, res);
  } catch (err) {
    console.error(err);
    return sendJSON(res, 500, { error: "サーバーエラー" });
  }
});

function serveStatic(pathname, res) {
  let rel = pathname === "/" ? "/index.html" : pathname;
  // ディレクトリトラバーサル防止
  const filePath = path.normalize(path.join(PUBLIC, rel));
  if (!filePath.startsWith(PUBLIC)) {
    res.writeHead(403);
    return res.end("Forbidden");
  }
  fs.readFile(filePath, (err, buf) => {
    if (err) {
      // SPA 的フォールバックはせず、admin など実ファイルのみ
      res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
      return res.end("<h1>404 Not Found</h1>");
    }
    const ext = path.extname(filePath).toLowerCase();
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(buf);
  });
}

server.listen(PORT, () => {
  if (!fs.existsSync(ORDERS_FILE)) writeOrders([]);
  console.log(`\n☕  MAMETO COFFEE サーバー起動`);
  console.log(`    お店:   http://localhost:${PORT}/`);
  console.log(`    管理:   http://localhost:${PORT}/admin.html\n`);
});
