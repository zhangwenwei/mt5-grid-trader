/* =========================================================
   MAMETO COFFEE — フロントエンド
   メニュー読み込み / カート / チェックアウト / 注文送信
   ========================================================= */
(() => {
  "use strict";

  const yen = (n) => "¥" + Number(n).toLocaleString("ja-JP");
  const $ = (sel) => document.querySelector(sel);

  const state = {
    menu: null,
    flatItems: {}, // id -> item
    cart: loadCart(), // [{id, qty}]
    activeCat: "all",
  };

  // ---------- 永続化 ----------
  function loadCart() {
    try {
      return JSON.parse(localStorage.getItem("mameto_cart") || "[]");
    } catch {
      return [];
    }
  }
  function saveCart() {
    localStorage.setItem("mameto_cart", JSON.stringify(state.cart));
  }

  // ---------- 初期化 ----------
  document.addEventListener("DOMContentLoaded", init);

  async function init() {
    $("#year").textContent = new Date().getFullYear();
    setupHeader();
    setupDrawer();
    setupCheckout();
    await loadMenu();
    renderCart();
  }

  function setupHeader() {
    const header = $("#siteHeader");
    const onScroll = () => header.classList.toggle("scrolled", window.scrollY > 40);
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  // ---------- メニュー ----------
  async function loadMenu() {
    try {
      const res = await fetch("/api/menu");
      if (!res.ok) throw new Error("menu fetch failed");
      state.menu = await res.json();
    } catch (e) {
      $("#menuGrid").innerHTML =
        '<div class="menu-loading">メニューを読み込めませんでした。時間をおいてお試しください。</div>';
      return;
    }

    // フラット化 & 店舗情報
    for (const cat of state.menu.categories) {
      for (const it of cat.items) state.flatItems[it.id] = it;
    }
    renderShopInfo();
    renderTabs();
    renderMenu();
  }

  function renderShopInfo() {
    const s = state.menu.shop;
    document.title = `${s.name} — 自家焙煎スペシャルティコーヒー`;
    const rows = [
      ["営業時間", s.hours],
      ["所在地", s.address],
      ["電話", s.phone],
    ];
    $("#shopInfo").innerHTML = rows
      .map(([k, v]) => `<li><span class="vk">${k}</span><span class="vv">${esc(v)}</span></li>`)
      .join("");
    $("#pickupNote").textContent = s.pickupNote;
  }

  function renderTabs() {
    const tabs = [{ id: "all", name: "すべて" }, ...state.menu.categories];
    $("#menuTabs").innerHTML = tabs
      .map(
        (c) =>
          `<button class="menu-tab ${c.id === state.activeCat ? "active" : ""}" data-cat="${c.id}">${esc(
            c.name
          )}</button>`
      )
      .join("");
    $("#menuTabs")
      .querySelectorAll(".menu-tab")
      .forEach((btn) =>
        btn.addEventListener("click", () => {
          state.activeCat = btn.dataset.cat;
          renderTabs();
          renderMenu();
        })
      );
  }

  function renderMenu() {
    const grid = $("#menuGrid");
    const cats =
      state.activeCat === "all"
        ? state.menu.categories
        : state.menu.categories.filter((c) => c.id === state.activeCat);

    let html = "";
    for (const cat of cats) {
      if (state.activeCat === "all") {
        html += `<h3 class="menu-cat-title">${esc(cat.name)}</h3>`;
      }
      for (const it of cat.items) html += itemCard(it);
    }
    grid.innerHTML = html;
    grid.querySelectorAll(".add-btn").forEach((btn) =>
      btn.addEventListener("click", () => addToCart(btn.dataset.id))
    );
  }

  function itemCard(it) {
    const badge = it.badge
      ? `<span class="menu-badge ${it.badge === "限定" ? "limited" : ""}">${esc(it.badge)}</span>`
      : "";
    return `
      <article class="menu-item">
        <div class="menu-thumb">${emojiFor(it)}</div>
        <div class="menu-info">
          <div class="menu-item-top">
            <h4>${esc(it.name)}</h4>${badge}
          </div>
          <div class="menu-en">${esc(it.en || "")}</div>
          <p class="menu-desc">${esc(it.desc || "")}</p>
          <div class="menu-item-bottom">
            <div class="menu-price">${yen(it.price)}<small>税込</small></div>
            <button class="add-btn" data-id="${it.id}" aria-label="${esc(it.name)}をカートに追加">＋</button>
          </div>
        </div>
      </article>`;
  }

  function emojiFor(it) {
    const map = {
      latte: "🥛", cappuccino: "☕", mocha: "🍫", americano: "☕", espresso: "☕",
      "house-blend": "☕", "single-ethiopia": "🌸", "single-guatemala": "🍫", "cold-brew": "🧊",
      "matcha-latte": "🍵", chai: "🫖", cocoa: "🍫",
      croissant: "🥐", "banana-bread": "🍌", cheesecake: "🍰", "beans-200": "🫘",
    };
    return map[it.id] || "☕";
  }

  // ---------- カート操作 ----------
  function addToCart(id) {
    const line = state.cart.find((l) => l.id === id);
    if (line) line.qty++;
    else state.cart.push({ id, qty: 1 });
    saveCart();
    renderCart();
    bumpCart();
    toast(`${state.flatItems[id].name} を追加しました`);
  }

  function changeQty(id, delta) {
    const line = state.cart.find((l) => l.id === id);
    if (!line) return;
    line.qty += delta;
    if (line.qty <= 0) state.cart = state.cart.filter((l) => l.id !== id);
    saveCart();
    renderCart();
  }

  function cartTotal() {
    return state.cart.reduce((sum, l) => {
      const it = state.flatItems[l.id];
      return sum + (it ? it.price * l.qty : 0);
    }, 0);
  }
  function cartCount() {
    return state.cart.reduce((s, l) => s + l.qty, 0);
  }

  function renderCart() {
    const body = $("#cartBody");
    const count = cartCount();
    $("#cartCount").textContent = count;

    if (count === 0) {
      body.innerHTML = `
        <div class="cart-empty">
          <div class="big">🛒</div>
          <p>カートは空です</p>
          <p style="font-size:.85rem">メニューからお好きな一杯をどうぞ。</p>
        </div>`;
      $("#cartTotal").textContent = yen(0);
      $("#checkoutBtn").disabled = true;
      return;
    }

    body.innerHTML = state.cart
      .map((l) => {
        const it = state.flatItems[l.id];
        if (!it) return "";
        return `
        <div class="cart-line">
          <div class="cart-line-thumb">${emojiFor(it)}</div>
          <div class="cart-line-info">
            <h5>${esc(it.name)}</h5>
            <div class="price">${yen(it.price)}</div>
            <div class="qty-control">
              <button data-act="dec" data-id="${it.id}" aria-label="減らす">−</button>
              <span class="qty">${l.qty}</span>
              <button data-act="inc" data-id="${it.id}" aria-label="増やす">＋</button>
            </div>
          </div>
          <div class="cart-line-sub">${yen(it.price * l.qty)}</div>
        </div>`;
      })
      .join("");

    body.querySelectorAll("button[data-act]").forEach((btn) =>
      btn.addEventListener("click", () =>
        changeQty(btn.dataset.id, btn.dataset.act === "inc" ? 1 : -1)
      )
    );

    $("#cartTotal").textContent = yen(cartTotal());
    $("#checkoutBtn").disabled = false;
  }

  function bumpCart() {
    const el = $("#cartCount");
    el.animate(
      [{ transform: "scale(1)" }, { transform: "scale(1.5)" }, { transform: "scale(1)" }],
      { duration: 300 }
    );
  }

  // ---------- ドロワー ----------
  function setupDrawer() {
    const drawer = $("#cartDrawer");
    const overlay = $("#drawerOverlay");
    const open = () => {
      drawer.classList.add("open");
      overlay.classList.add("open");
    };
    const close = () => {
      drawer.classList.remove("open");
      overlay.classList.remove("open");
    };
    $("#openCart").addEventListener("click", open);
    $("#closeCart").addEventListener("click", close);
    overlay.addEventListener("click", close);
    $("#checkoutBtn").addEventListener("click", () => {
      close();
      openCheckout();
    });
  }

  // ---------- チェックアウト ----------
  function setupCheckout() {
    $("#closeCheckout").addEventListener("click", closeCheckout);
    $("#checkoutOverlay").addEventListener("click", (e) => {
      if (e.target === $("#checkoutOverlay")) closeCheckout();
    });
    $("#checkoutForm").addEventListener("submit", submitOrder);
    $("#doneClose").addEventListener("click", () => {
      $("#doneOverlay").classList.remove("open");
    });
  }

  function openCheckout() {
    if (cartCount() === 0) return;
    renderCheckoutSummary();
    $("#checkoutOverlay").classList.add("open");
  }
  function closeCheckout() {
    $("#checkoutOverlay").classList.remove("open");
  }

  function renderCheckoutSummary() {
    const lines = state.cart
      .map((l) => {
        const it = state.flatItems[l.id];
        if (!it) return "";
        return `<div class="cs-line"><span>${esc(it.name)} × ${l.qty}</span><span>${yen(
          it.price * l.qty
        )}</span></div>`;
      })
      .join("");
    $("#checkoutSummary").innerHTML =
      lines + `<div class="cs-total"><span>合計</span><span>${yen(cartTotal())}</span></div>`;
  }

  async function submitOrder(e) {
    e.preventDefault();
    const btn = $("#placeOrderBtn");
    const form = e.target;
    const payload = {
      customerName: form.customerName.value.trim(),
      phone: form.phone.value.trim(),
      pickupTime: form.pickupTime.value,
      note: form.note.value.trim(),
      items: state.cart.map((l) => ({ id: l.id, qty: l.qty })),
    };

    if (!payload.customerName) {
      toast("お名前を入力してください");
      return;
    }
    if (payload.items.length === 0) {
      toast("カートが空です");
      return;
    }

    btn.disabled = true;
    btn.textContent = "送信中…";
    try {
      const res = await fetch("/api/orders", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "注文に失敗しました");

      // 成功
      state.cart = [];
      saveCart();
      renderCart();
      form.reset();
      closeCheckout();
      showDone(data.order);
    } catch (err) {
      toast(err.message || "注文に失敗しました");
    } finally {
      btn.disabled = false;
      btn.textContent = "この内容で注文する";
    }
  }

  function showDone(order) {
    $("#doneNumber").textContent = "#" + order.number;
    const pickupLabel = {
      asap: "約15分後",
      "30min": "30分後",
      "1hour": "1時間後",
      later: "店頭でお伝えください",
    }[order.pickupTime] || "";
    $("#doneText").innerHTML =
      `${esc(order.customerName)} 様、ご注文を承りました。<br />` +
      `お受け取りの目安：<strong>${pickupLabel}</strong><br />` +
      `合計 <strong>${yen(order.total)}</strong>（店頭でお支払い）`;
    $("#doneOverlay").classList.add("open");
  }

  // ---------- ユーティリティ ----------
  let toastTimer;
  function toast(msg) {
    const t = $("#toast");
    t.textContent = msg;
    t.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove("show"), 2400);
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }
})();
