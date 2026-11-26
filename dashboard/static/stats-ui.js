window.StatsUI = (function () {
  const chartState = new Map();

  const zeroLinePlugin = {
    id: "makingZeroLine",
    beforeDraw(chart) {
      const { ctx, chartArea, scales } = chart;
      if (!chartArea || !scales.y) return;
      const y0 = scales.y.getPixelForValue(0);
      if (y0 < chartArea.top || y0 > chartArea.bottom) return;
      ctx.save();
      ctx.strokeStyle = "rgba(139,156,179,.45)";
      ctx.setLineDash([4, 4]);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(chartArea.left, y0);
      ctx.lineTo(chartArea.right, y0);
      ctx.stroke();
      ctx.restore();
    },
  };

  function parseTs(ts) {
    if (!ts) return Date.now();
    const s = String(ts).trim();
    if (s.endsWith("Z")) return new Date(s).getTime();
    return new Date(s + "Z").getTime();
  }

  function chartOptions(showTotal) {
    return {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: "index", intersect: false },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: "#121820",
          borderColor: "#243044",
          borderWidth: 1,
          titleFont: { family: "Consolas, ui-monospace, monospace", size: 11 },
          bodyFont: { family: "Consolas, ui-monospace, monospace", size: 11 },
          callbacks: {
            label(ctx) {
              const v = ctx.parsed.y;
              if (v == null || Number.isNaN(v)) return "";
              const s = v >= 0 ? "+" : "";
              return `${ctx.dataset.label}: ${s}${v.toFixed(2)}`;
            },
          },
        },
      },
      scales: {
        x: {
          type: "time",
          time: {
            tooltipFormat: "HH:mm:ss",
            displayFormats: { minute: "HH:mm", hour: "HH:mm", day: "MMM d" },
          },
          grid: { color: "rgba(36,48,68,.85)" },
          ticks: { color: "#8b9cb3", maxTicksLimit: 8, font: { size: 10 } },
        },
        y: {
          grid: { color: "rgba(36,48,68,.85)" },
          ticks: {
            color: "#8b9cb3",
            font: { size: 10 },
            callback(v) {
              const n = Number(v);
              return (n >= 0 ? "+" : "") + n.toFixed(2);
            },
          },
        },
      },
    };
  }

  function buildDatasets(series, showTotal) {
    const realized = (series || []).map((p) => ({
      x: parseTs(p.ts),
      y: p.realized_cum ?? 0,
    }));
    if (!realized.length) {
      const t = Date.now();
      realized.push({ x: t - 3600000, y: 0 }, { x: t, y: 0 });
    }
    const datasets = [
      {
        label: showTotal ? "Realized" : "Realized PnL",
        data: realized,
        borderColor: "#3ddc84",
        backgroundColor: "rgba(61,220,132,0.18)",
        borderWidth: showTotal ? 1.5 : 2,
        pointRadius: 0,
        tension: 0.15,
        fill: true,
      },
    ];
    if (showTotal) {
      const total = (series || [])
        .filter((p) => p.total_est != null && Number.isFinite(p.total_est))
        .map((p) => ({ x: parseTs(p.ts), y: p.total_est }));
      if (total.length) {
        datasets.push({
          label: "Total est.",
          data: total,
          borderColor: "#f0b429",
          backgroundColor: "rgba(240,180,41,0.12)",
          borderWidth: 2.5,
          pointRadius: 0,
          tension: 0.15,
          fill: true,
        });
      }
    }
    return datasets;
  }

  function ensureChart(article) {
    const canvas = article.querySelector("canvas.stats-chart");
    if (!canvas || typeof Chart === "undefined") return null;
    let state = chartState.get(article);
    if (state?.chart) return state.chart;
    state = state || {};
    state.chart = new Chart(canvas, {
      type: "line",
      plugins: [zeroLinePlugin],
      data: { datasets: [] },
      options: chartOptions(false),
    });
    chartState.set(article, state);
    return state.chart;
  }

  function updateLegend(article, showTotal) {
    article.querySelectorAll(".stats-pnl-legend [data-series]").forEach((el) => {
      const key = el.dataset.series;
      const on = key === "realized" || (key === "total" && showTotal);
      el.classList.toggle("on", on);
      el.classList.toggle("hidden", key === "total" && !showTotal);
    });
  }

  function drawChart(article, series, showTotal) {
    const chart = ensureChart(article);
    if (!chart) return;
    chart.options = chartOptions(showTotal);
    chart.data.datasets = buildDatasets(series, showTotal);
    const xs = chart.data.datasets.flatMap((d) => d.data.map((p) => p.x));
    if (xs.length >= 2) {
      const min = Math.min(...xs);
      const max = Math.max(...xs);
      const spanH = (max - min) / 3600000;
      const unit = spanH > 72 ? "day" : spanH > 6 ? "hour" : "minute";
      chart.options.scales.x.time.unit = unit;
      chart.options.scales.x.min = min;
      chart.options.scales.x.max = max;
    } else {
      delete chart.options.scales.x.min;
      delete chart.options.scales.x.max;
    }
    chart.update("none");
    updateLegend(article, showTotal);
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

    const showTotal = article.querySelector(".stats-chart-mode")?.value === "total";
    const wrap = article.querySelector(".stats-chart-wrap");
    const empty = article.querySelector(".stats-empty");
    if (!body.has_data) {
      empty?.classList.remove("hidden");
      wrap?.classList.add("stats-chart-wrap--idle");
    } else {
      empty?.classList.add("hidden");
      wrap?.classList.remove("stats-chart-wrap--idle");
    }
    drawChart(article, body.pnl_series || [], showTotal);
  }

  function bindCard(article, runTag) {
    const rangeSel = article.querySelector(".stats-range");
    const chartMode = article.querySelector(".stats-chart-mode");
    const refresh = () => loadAndRender(article, runTag, rangeSel?.value || "session");
    rangeSel?.addEventListener("change", refresh);
    chartMode?.addEventListener("change", refresh);
    refresh();
    chartState.set(article, { runTag, refresh, chart: chartState.get(article)?.chart });
  }

  function refreshAll() {
    chartState.forEach(({ refresh }) => refresh?.());
  }

  function destroyAll() {
    chartState.forEach((state) => {
      try {
        state.chart?.destroy();
      } catch (_) {
        /* DOM replaced */
      }
    });
    chartState.clear();
  }

  return { bindCard, refreshAll, destroyAll };
})();