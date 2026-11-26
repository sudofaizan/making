window.StatsUI = (function () {
  const chartState = new Map();

  function drawChart(canvas, series, showTotal) {
    if (!canvas || !series.length) return;
    const ctx = canvas.getContext("2d");
    const w = canvas.width;
    const h = canvas.height;
    const pad = { l: 36, r: 8, t: 8, b: 22 };
    ctx.clearRect(0, 0, w, h);
    const vals = series.map((p) => {
      if (showTotal && p.total_est != null) return p.total_est;
      return p.realized_cum ?? 0;
    });
    const minY = Math.min(0, ...vals);
    const maxY = Math.max(0.01, ...vals);
    const span = maxY - minY || 1;

    const x = (i) => pad.l + (i / Math.max(1, series.length - 1)) * (w - pad.l - pad.r);
    const y = (v) => pad.t + (1 - (v - minY) / span) * (h - pad.t - pad.b);

    ctx.strokeStyle = "#2d3a4f";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(pad.l, y(0));
    ctx.lineTo(w - pad.r, y(0));
    ctx.stroke();

    ctx.strokeStyle = showTotal ? "#59c2ff" : "#3dd68c";
    ctx.lineWidth = 2;
    ctx.beginPath();
    series.forEach((p, i) => {
      const v = showTotal && p.total_est != null ? p.total_est : p.realized_cum ?? 0;
      const px = x(i);
      const py = y(v);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    });
    ctx.stroke();

    ctx.fillStyle = "#8b9cb3";
    ctx.font = "10px ui-monospace, monospace";
    ctx.fillText(maxY.toFixed(2), 4, y(maxY) + 3);
    ctx.fillText(minY.toFixed(2), 4, y(minY) + 3);
  }

  async function loadAndRender(article, runTag, range) {
    const res = await fetch(
      `${window.MAKING_BASE || "/making"}/api/stats?run_tag=${encodeURIComponent(runTag)}&range=${encodeURIComponent(range)}`,
      { credentials: "include" }
    );
    if (!res.ok) return;
    const body = await res.json();
    if (!body.ok) return;

    const c = body.counters || {};
    article.querySelector(".stat-orders").textContent = c.orders_created ?? 0;
    article.querySelector(".stat-baskets").textContent = c.baskets_closed ?? 0;
    article.querySelector(".stat-buy-closed").textContent = c.buy_closed ?? 0;
    article.querySelector(".stat-sell-closed").textContent = c.sell_closed ?? 0;
    article.querySelector(".stat-realized").textContent = (c.realized_pnl ?? 0).toFixed(2);
    article.querySelector(".stat-floating").textContent =
      body.current_floating_pnl != null ? body.current_floating_pnl.toFixed(2) : "—";
    article.querySelector(".stat-total").textContent = (body.total_pnl_est ?? 0).toFixed(2);

    const hint = article.querySelector(".stats-range-hint");
    if (body.range === "session" && body.session_from) {
      hint.textContent = `Since ${body.session_from} (last init start)`;
    } else if (body.range === "all") {
      hint.textContent = "All recorded events";
    } else {
      hint.textContent = "";
    }

    const canvas = article.querySelector("canvas.stats-chart");
    const showTotal = article.querySelector(".stats-chart-mode")?.value === "total";
    drawChart(canvas, body.pnl_series || [], showTotal);

    if (!body.has_data) {
      article.querySelector(".stats-empty")?.classList.remove("hidden");
    } else {
      article.querySelector(".stats-empty")?.classList.add("hidden");
    }
  }

  function bindCard(article, runTag) {
    const rangeSel = article.querySelector(".stats-range");
    const chartMode = article.querySelector(".stats-chart-mode");
    const refresh = () => loadAndRender(article, runTag, rangeSel?.value || "session");
    rangeSel?.addEventListener("change", refresh);
    chartMode?.addEventListener("change", refresh);
    refresh();
    chartState.set(article, { runTag, refresh });
  }

  function refreshAll() {
    chartState.forEach(({ refresh }) => refresh());
  }

  return { bindCard, refreshAll };
})();