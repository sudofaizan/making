const BASE = window.MAKING_BASE || "/making";

function api(path, options = {}) {
  return fetch(`${BASE}${path}`, { credentials: "include", ...options });
}

function showBanner(msg, isError = true) {
  const el = document.getElementById("banner");
  el.textContent = msg;
  el.classList.toggle("hidden", !msg);
  el.style.borderColor = isError ? "var(--warn)" : "var(--up)";
}

function badgeClass(summary) {
  if (summary.exited === 0) return "ok";
  if (summary.up === 0) return "warn";
  return "";
}

function workerRow(w) {
  const up = w.running;
  return `<tr>
    <td><span class="dot ${up ? "up" : "down"}"></span>${w.worker}</td>
    <td>${up ? "Up" : "Exited"}</td>
    <td>${w.pid ?? "—"}</td>
    <td>${w.uptime || "—"}</td>
    <td class="muted">${w.status}</td>
  </tr>`;
}

function stackCard(stack) {
  const s = stack.summary;
  const bc = badgeClass(s);
  const deletable = stack.env_file && stack.env_file.startsWith("env/");
  const closeBtn = deletable
    ? `<button type="button" class="stack-close btn-del-stack" data-env="${stack.env_file}" data-up="${s.up}" data-run-tag="${stack.run_tag}" title="Remove stack" aria-label="Remove stack">×</button>`
    : "";
  return `
    <article class="stack" data-env="${stack.env_file}">
      ${closeBtn}
      <div class="stack-hd">
        <div class="stack-title">
          <h2>${stack.run_tag}</h2>
          <span class="muted">${stack.symbol}</span>
          <span class="badge ${bc}">${s.up}/${s.total} up</span>
          <span class="badge">${stack.env_file}</span>
        </div>
        <div class="stack-actions">
          <button type="button" class="btn ghost btn-edit-env" data-env="${stack.env_file}">Edit .env</button>
          <button type="button" class="btn start" data-action="start">Start</button>
          <button type="button" class="btn stop" data-action="stop">Stop</button>
          <button type="button" class="btn" data-action="restart">Restart</button>
          <label class="chk" title="INIT_SKIP_PRIMARY=1">
            <input type="checkbox" class="skip-primary" /> Skip PRIMARY on start
          </label>
        </div>
      </div>
      <table>
        <thead><tr>
          <th>Worker</th><th>State</th><th>PID</th><th>Uptime</th><th>Detail</th>
        </tr></thead>
        <tbody>${stack.workers.map(workerRow).join("")}</tbody>
      </table>
      <section class="stats-panel">
        <div class="stats-toolbar">
          <span class="muted">Stats</span>
          <select class="stats-range env-select">
            <option value="session" selected>This session</option>
            <option value="all">All time</option>
          </select>
          <select class="stats-chart-mode env-select" title="PnL curve">
            <option value="realized">Realized PnL</option>
            <option value="total">Total (realized + float)</option>
          </select>
          <span class="stats-range-hint muted"></span>
        </div>
        <p class="stats-empty muted hidden">No stats yet — events fill in after orders, basket closes, and ~1m samples.</p>
        <canvas class="stats-chart" width="640" height="120"></canvas>
        <div class="stats-grid">
          <div><span class="muted">Orders</span><strong class="stat-orders">—</strong></div>
          <div><span class="muted">Baskets closed</span><strong class="stat-baskets">—</strong></div>
          <div><span class="muted">Buys closed</span><strong class="stat-buy-closed">—</strong></div>
          <div><span class="muted">Sells closed</span><strong class="stat-sell-closed">—</strong></div>
          <div><span class="muted">Realized</span><strong class="stat-realized">—</strong></div>
          <div><span class="muted">Floating</span><strong class="stat-floating">—</strong></div>
          <div><span class="muted">Total est.</span><strong class="stat-total">—</strong></div>
        </div>
      </section>
    </article>`;
}

function render(data) {
  const total = data.total || {};
  document.getElementById("meta").textContent =
    `Updated ${data.generated_at || "—"} · ${total.stacks ?? "?"} stacks · ${total.up ?? 0} up · ${total.exited ?? 0} exited`;
  document.getElementById("stacks").innerHTML = (data.stacks || []).map(stackCard).join("");
  document.querySelectorAll(".stack-actions button[data-action]").forEach((btn) => {
    btn.addEventListener("click", () => onControl(btn));
  });
  document.querySelectorAll(".btn-edit-env").forEach((btn) => {
    btn.addEventListener("click", () => EnvEditor.openEdit(btn.dataset.env));
  });
  document.querySelectorAll(".btn-del-stack").forEach((btn) => {
    btn.addEventListener("click", () =>
      EnvEditor.deleteStack(btn.dataset.env, Number(btn.dataset.up || 0), btn.dataset.runTag || "")
    );
  });
  document.querySelectorAll("article.stack").forEach((article) => {
    const tag = article.querySelector(".stack-title h2")?.textContent;
    if (tag) StatsUI.bindCard(article, tag);
  });
}

async function loadStatus() {
  const res = await api("/api/status");
  if (res.status === 401) {
    location.href = `${BASE}/login`;
    return;
  }
  const body = await res.json();
  if (!body.ok) {
    showBanner(body.error || "Status failed");
    return;
  }
  showBanner("", false);
  render(body);
  if (window.StatsUI) StatsUI.refreshAll();
}

async function onControl(btn) {
  const stack = btn.closest(".stack");
  const env_file = stack.dataset.env;
  const action = btn.dataset.action;
  const skip = stack.querySelector(".skip-primary")?.checked && action === "start";
  btn.disabled = true;
  showBanner(`Running ${action} on ${env_file}…`, false);
  try {
    const res = await api("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ env_file, action, skip_primary: skip }),
    });
    if (res.status === 401) {
      location.href = `${BASE}/login`;
      return;
    }
    const body = await res.json();
    if (!body.ok) {
      showBanner(body.error || `Control failed (${res.status})`);
    } else if (!body.result?.ok) {
      showBanner(`init ${action} failed — see server log`);
    } else {
      showBanner(`${action} OK for ${env_file}`, false);
      await loadStatus();
    }
  } catch (e) {
    showBanner(String(e));
  } finally {
    btn.disabled = false;
  }
}

async function logout() {
  await api("/api/logout", { method: "POST" });
  location.href = `${BASE}/login`;
}

let timer = null;
function setupRefresh() {
  const auto = document.getElementById("autoRefresh");
  const tick = () => {
    if (auto.checked) loadStatus();
  };
  if (timer) clearInterval(timer);
  timer = setInterval(tick, 10000);
  loadStatus();
}

window.loadStatus = loadStatus;

document.getElementById("btnRefresh").addEventListener("click", loadStatus);
document.getElementById("btnLogout").addEventListener("click", logout);
document.getElementById("autoRefresh").addEventListener("change", setupRefresh);
EnvEditor.bind();
setupRefresh();