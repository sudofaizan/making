const BASE = window.MAKING_BASE || "/making";

function showErr(msg) {
  const el = document.getElementById("loginErr");
  el.textContent = msg || "";
  el.classList.toggle("hidden", !msg);
}

document.getElementById("loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  showErr("");
  const password = document.getElementById("password").value;
  const btn = e.target.querySelector("button[type=submit]");
  btn.disabled = true;
  try {
    const res = await fetch(`${BASE}/api/login`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password }),
    });
    const body = await res.json();
    if (!res.ok || !body.ok) {
      showErr(body.error === "wrong_password" ? "Wrong password" : (body.error || "Login failed"));
      return;
    }
    location.href = `${BASE}/`;
  } catch (err) {
    showErr(String(err));
  } finally {
    btn.disabled = false;
  }
});

fetch(`${BASE}/api/session`, { credentials: "include" })
  .then((r) => r.json())
  .then((body) => {
    if (body.logged_in) location.href = `${BASE}/`;
  })
  .catch(() => {});