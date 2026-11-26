/* global EnvEditor — uses window.loadStatus from app.js */
window.EnvEditor = (function () {
  let schema = { required: [], optional: [], help: {} };
  let mode = "edit"; // create | edit
  let envFile = "";
  let modalEl, createOpts, rawEl, formPane, errEl, titleEl;

  function qs(id) {
    return document.getElementById(id);
  }

  function setErr(msg) {
    errEl.textContent = msg || "";
    errEl.classList.toggle("hidden", !msg);
  }

  function parseVars(text) {
    const out = {};
    text.split("\n").forEach((line) => {
      const s = line.trim();
      if (!s || s.startsWith("#") || !s.includes("=")) return;
      const i = s.indexOf("=");
      const k = s.slice(0, i).trim();
      out[k] = s.slice(i + 1).trim();
    });
    return out;
  }

  function mergeVar(text, key, value) {
    const lines = text.split("\n");
    let found = false;
    const out = lines.map((line) => {
      if (line.trim().startsWith("#") || !line.includes("=")) return line;
      const i = line.indexOf("=");
      const k = line.slice(0, i).trim();
      if (k === key) {
        found = true;
        return `${key}=${value}`;
      }
      return line;
    });
    if (!found) out.push(`${key}=${value}`);
    return out.join("\n");
  }

  function renderForm() {
    const vars = parseVars(rawEl.value);
    const keys = [...schema.required, ...schema.optional.filter((k) => vars[k] !== undefined)];
    const uniq = [...new Set(keys)];
    formPane.innerHTML = uniq
      .map((key) => {
        const hint = schema.help[key] ? ` title="${schema.help[key]}"` : "";
        const val = vars[key] ?? "";
        return `<label class="env-field"${hint}><span>${key}</span>
          <input type="text" data-key="${key}" value="${val.replace(/"/g, "&quot;")}" /></label>`;
      })
      .join("");
    formPane.querySelectorAll("input").forEach((inp) => {
      inp.addEventListener("change", () => {
        rawEl.value = mergeVar(rawEl.value, inp.dataset.key, inp.value);
      });
    });
  }

  function switchTab(tab) {
    document.querySelectorAll(".env-tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
    rawEl.classList.toggle("hidden", tab !== "raw");
    formPane.classList.toggle("hidden", tab !== "form");
    if (tab === "form") renderForm();
  }

  async function loadSchema() {
    if (schema.required.length) return;
    const res = await api("/api/env/schema");
    const body = await res.json();
    if (body.ok) schema = body;
  }

  async function fillCloneOptions() {
    const sel = qs("envCloneSelect");
    const res = await api("/api/envs");
    const body = await res.json();
    const files = (body.env_files || []).filter((f) => f !== "var.env");
    sel.innerHTML = '<option value="">Clone from…</option>' +
      files.map((f) => `<option value="${f}">${f}</option>`).join("");
  }

  async function loadContentFromApi(path) {
    const res = await api(`/api/env/file?path=${encodeURIComponent(path)}`);
    const body = await res.json();
    if (!body.ok) throw new Error(body.error || "load failed");
    rawEl.value = body.content;
    envFile = body.env_file;
    renderForm();
  }

  async function openCreate() {
    mode = "create";
    envFile = "";
    titleEl.textContent = "Add stack";
    createOpts.classList.remove("hidden");
    qs("envNewFilename").value = "";
    rawEl.value = "";
    setErr("");
    modalEl.classList.remove("hidden");
    await loadSchema();
    await fillCloneOptions();
    switchTab("form");
    const res = await api("/api/env/template");
    const body = await res.json();
    if (body.ok) rawEl.value = body.content;
    renderForm();
  }

  async function openEdit(env_file) {
    mode = "edit";
    envFile = env_file;
    titleEl.textContent = `Edit ${env_file}`;
    createOpts.classList.add("hidden");
    setErr("");
    modalEl.classList.remove("hidden");
    await loadSchema();
    await loadContentFromApi(env_file);
    switchTab("form");
  }

  function close() {
    modalEl.classList.add("hidden");
    setErr("");
  }

  async function save() {
    setErr("");
    switchTab("raw");
    const content = rawEl.value;
    const payload = { content };
    let url = "/api/env/save";
    if (mode === "create") {
      payload.create = true;
      const fname = qs("envNewFilename").value.trim();
      if (!fname) {
        setErr("Enter filename (e.g. ETHUSD.env)");
        switchTab("form");
        return;
      }
      payload.filename = fname;
    } else {
      payload.env_file = envFile;
    }
    const res = await api(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const body = await res.json();
    if (!body.ok) {
      setErr(body.error || "Save failed");
      return;
    }
    close();
    showBanner(mode === "create" ? `Created ${body.env_file}` : `Saved ${body.env_file}`, false);
    await window.loadStatus();
  }

  async function deleteStack(env_file) {
    if (!env_file.startsWith("env/")) {
      showBanner("var.env cannot be deleted — only env/*.env stacks");
      return;
    }
    const ok = confirm(
      `Delete stack ${env_file}?\nWorkers will be stopped and the env file removed.`
    );
    if (!ok) return;
    const res = await api("/api/env/delete", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ env_file, stop_workers: true }),
    });
    const body = await res.json();
    if (!body.ok) {
      showBanner(body.error || "Delete failed");
      return;
    }
    showBanner(`Deleted ${env_file}`, false);
    await window.loadStatus();
  }

  function bind() {
    modalEl = qs("envModal");
    createOpts = qs("envCreateOpts");
    rawEl = qs("envRawEditor");
    formPane = qs("envFormPane");
    errEl = qs("envModalErr");
    titleEl = qs("envModalTitle");

    qs("btnAddStack").addEventListener("click", openCreate);
    qs("envModalClose").addEventListener("click", close);
    qs("envCancelBtn").addEventListener("click", close);
    qs("envSaveBtn").addEventListener("click", save);

    document.querySelectorAll(".env-tab").forEach((b) => {
      b.addEventListener("click", () => switchTab(b.dataset.tab));
    });

    qs("envFromTemplate").addEventListener("click", async () => {
      const res = await api("/api/env/template");
      const body = await res.json();
      if (body.ok) {
        rawEl.value = body.content;
        renderForm();
      }
    });

    qs("envCloneSelect").addEventListener("change", async (e) => {
      const v = e.target.value;
      if (!v) return;
      const res = await api(`/api/env/template?clone=${encodeURIComponent(v)}`);
      const body = await res.json();
      if (body.ok) {
        rawEl.value = body.content;
        const base = v.split("/").pop();
        qs("envNewFilename").value = base;
        renderForm();
      }
    });

    qs("envFileUpload").addEventListener("change", async (e) => {
      const file = e.target.files?.[0];
      if (!file) return;
      const text = await file.text();
      rawEl.value = text;
      if (!qs("envNewFilename").value) qs("envNewFilename").value = file.name;
      const vars = parseVars(text);
      if (vars.RUN_TAG) qs("envNewFilename").value = `${vars.RUN_TAG}.env`;
      renderForm();
      e.target.value = "";
    });

    modalEl.addEventListener("click", (ev) => {
      if (ev.target === modalEl) close();
    });
  }

  return { bind, openCreate, openEdit, deleteStack };
})();