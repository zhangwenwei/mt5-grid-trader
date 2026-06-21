/* MAMETO COFFEE — 注文管理ダッシュボード */
(() => {
  "use strict";
  const $ = (s) => document.querySelector(s);
  const yen = (n) => "¥" + Number(n).toLocaleString("ja-JP");

  const STATUS = {
    received: { label: "受付", next: "preparing" },
    preparing: { label: "準備中", next: "ready" },
    ready: { label: "受取可", next: "completed" },
    completed: { label: "完了", next: null },
    cancelled: { label: "キャンセル", next: null },
  };
  const PICKUP = { asap: "約15分後", "30min": "30分後", "1hour": "1時間後", later: "店頭で確認" };

  const state = { orders: [], filter: "active", timer: null };

  document.addEventListener("DOMContentLoaded", () => {
    $("#refreshBtn").addEventListener("click", load);
    $("#autoRefresh").addEventListener("change", setupAuto);
    renderFilters();
    load();
    setupAuto();
  });

  function setupAuto() {
    clearInterval(state.timer);
    if ($("#autoRefresh").checked) state.timer = setInterval(load, 8000);
  }

  async function load() {
    try {
      const res = await fetch("/api/orders");
      state.orders = await res.json();
      render();
    } catch {
      toast("注文の取得に失敗しました");
    }
  }

  function renderFilters() {
    const chips = [
      { id: "active", label: "対応中" },
      { id: "received", label: "受付" },
      { id: "preparing", label: "準備中" },
      { id: "ready", label: "受取可" },
      { id: "completed", label: "完了" },
      { id: "all", label: "すべて" },
    ];
    $("#filters").innerHTML = chips
      .map(
        (c) =>
          `<button class="filter-chip ${c.id === state.filter ? "active" : ""}" data-f="${c.id}">${c.label}</button>`
      )
      .join("");
    $("#filters")
      .querySelectorAll(".filter-chip")
      .forEach((b) =>
        b.addEventListener("click", () => {
          state.filter = b.dataset.f;
          renderFilters();
          render();
        })
      );
  }

  function render() {
    renderStats();
    const board = $("#board");
    let list = [...state.orders].sort((a, b) => b.number - a.number);
    if (state.filter === "active") {
      list = list.filter((o) => ["received", "preparing", "ready"].includes(o.status));
    } else if (state.filter !== "all") {
      list = list.filter((o) => o.status === state.filter);
    }

    if (list.length === 0) {
      board.innerHTML = `<div class="board-empty">該当する注文はありません ☕</div>`;
      return;
    }
    board.innerHTML = list.map(card).join("");
    board.querySelectorAll("button[data-id]").forEach((btn) =>
      btn.addEventListener("click", () => updateStatus(btn.dataset.id, btn.dataset.status))
    );
  }

  function renderStats() {
    const today = new Date().toDateString();
    const todays = state.orders.filter((o) => new Date(o.createdAt).toDateString() === today);
    const active = state.orders.filter((o) =>
      ["received", "preparing", "ready"].includes(o.status)
    ).length;
    const revenue = todays
      .filter((o) => o.status !== "cancelled")
      .reduce((s, o) => s + o.total, 0);
    const stats = [
      { label: "対応中の注文", value: active },
      { label: "本日の注文数", value: todays.length },
      { label: "本日の売上", value: yen(revenue), small: "" },
      { label: "総注文数", value: state.orders.length },
    ];
    $("#stats").innerHTML = stats
      .map(
        (s) => `<div class="stat-card"><div class="label">${s.label}</div><div class="value">${s.value}</div></div>`
      )
      .join("");
  }

  function card(o) {
    const st = STATUS[o.status] || { label: o.status };
    const items = o.items
      .map((it) => `<div class="oc-item"><span><span class="q">${it.qty}×</span>${esc(it.name)}</span><span>${yen(it.subtotal)}</span></div>`)
      .join("");
    const note = o.note ? `<div class="oc-note">📝 ${esc(o.note)}</div>` : "";
    const phone = o.phone ? ` · ${esc(o.phone)}` : "";

    let actions = "";
    if (st.next) {
      const nextLabel = { preparing: "準備開始", ready: "準備完了", completed: "受渡完了" }[st.next];
      actions += `<button class="act-${st.next}" data-id="${o.id}" data-status="${st.next}">${nextLabel}</button>`;
    }
    if (o.status !== "completed" && o.status !== "cancelled") {
      actions += `<button class="act-cancel" data-id="${o.id}" data-status="cancelled">取消</button>`;
    }

    return `
      <article class="order-card s-${o.status}">
        <div class="oc-head">
          <span class="oc-num">#${o.number}</span>
          <span class="oc-status st-${o.status}">${st.label}</span>
        </div>
        <div class="oc-customer">
          <div class="name">${esc(o.customerName)} 様</div>
          <div class="meta">${time(o.createdAt)} · 受取 ${PICKUP[o.pickupTime] || o.pickupTime}${phone}</div>
        </div>
        <div class="oc-items">${items}${note}</div>
        <div class="oc-foot">
          <div class="oc-total"><span>合計</span><span class="amt">${yen(o.total)}</span></div>
          <div class="oc-actions">${actions || '<span style="color:var(--muted);font-size:.85rem">対応完了</span>'}</div>
        </div>
      </article>`;
  }

  async function updateStatus(id, status) {
    try {
      const res = await fetch(`/api/orders/${id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status }),
      });
      if (!res.ok) throw new Error();
      await load();
      toast("ステータスを更新しました");
    } catch {
      toast("更新に失敗しました");
    }
  }

  function time(iso) {
    const d = new Date(iso);
    return d.toLocaleTimeString("ja-JP", { hour: "2-digit", minute: "2-digit" });
  }

  let tt;
  function toast(msg) {
    const t = $("#toast");
    t.textContent = msg;
    t.classList.add("show");
    clearTimeout(tt);
    tt = setTimeout(() => t.classList.remove("show"), 2200);
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }
})();
