// Capability preflight. Checks the shell-verifiable items in capabilities.json
// (cli.required + env.required block the gate; env.watched are surfaced but
// never block), prints a ✅/‼️/○ report, and opens or closes the edit/commit
// gate by writing/removing .claude/.state/preflight-ok. The MCP list is verified
// by the MODEL (a shell can't see MCP connections).
//
// Sandbox-Brain extra: the 3-place pin-agreement check (PINS.md ·
// DockerfileModifier.sh · build.yml). Drift is ‼️-loud but NEVER closes the
// gate — a bump-in-progress is exactly when you must still be able to edit.
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "fs";
import { execSync } from "child_process";
import { join } from "path";

const ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const STATE = join(ROOT, ".claude", ".state");
mkdirSync(STATE, { recursive: true });
const session = existsSync(join(STATE, "session-id")) ? readFileSync(join(STATE, "session-id"), "utf8").trim() : "manual";

const cap = JSON.parse(readFileSync(join(ROOT, "capabilities.json"), "utf8"));
const has = (cmd) => { try { execSync(`command -v ${cmd}`, { stdio: "ignore", shell: "/bin/bash" }); return true; } catch { return false; } };
const tick = (ok) => (ok ? "✅" : "‼️");

let requiredOk = true;
const out = ["── PREFLIGHT · Sandbox-Brain capability check ──"];

for (const c of cap.cli?.required ?? []) { const ok = has(c); if (!ok) requiredOk = false; out.push(`${tick(ok)} cli  ${c}${ok ? "" : "   (REQUIRED — missing)"}`); }
for (const o of cap.cli?.optional ?? []) { const ok = has(o.name); out.push(`${ok ? "✅" : "○ "} cli  ${o.name}${ok ? "" : "   — " + o.why}`); }
for (const e of cap.env?.required ?? []) { const ok = !!process.env[e.name]; if (!ok) requiredOk = false; out.push(`${tick(ok)} env  ${e.name}${ok ? "" : "   (REQUIRED — add to env secrets + restart)"}`); }

// Watched secrets never block the gate, but a missing one is loud — these are
// the keys the brain work actually needs (BRAIN_API_KEY / RENDER_API_KEY).
let missingWatched = 0;
for (const w of cap.env?.watched ?? []) { const ok = !!process.env[w.name]; if (!ok) missingWatched++; out.push(`${ok ? "✅" : "○ "} env  ${w.name}${ok ? "" : "   — MISSING (watched): " + w.why}`); }

// ── Pin agreement (Sandbox-Brain-specific, warn-only) ──
// CLAUDE.md rule: a pin bump is a deliberate 3-place edit. Verify the three
// places agree so drift is caught at boot, not in a failed CI build.
try {
  const dfmP = join(ROOT, "DockerfileModifier.sh"), byP = join(ROOT, ".github", "workflows", "build.yml"), pinsP = join(ROOT, "PINS.md");
  if (existsSync(dfmP) && existsSync(byP) && existsSync(pinsP)) {
    const dfm = readFileSync(dfmP, "utf8"), by = readFileSync(byP, "utf8"), pins = readFileSync(pinsP, "utf8");
    const vDfm = (dfm.match(/build_data\/version[^\n]*\|\|\s*echo\s+"([^"]+)"/) || [])[1];
    const vBy = (by.match(/gitnexus_version:[\s\S]{0,200}?default:\s*"([^"]+)"/) || [])[1];
    const vPins = (pins.match(/gitnexus@([0-9][0-9A-Za-z.\-]*)/) || [])[1];
    if (vDfm && vDfm === vBy && vDfm === vPins) out.push(`✅ pins gitnexus@${vDfm} agrees ×3 (PINS.md · DockerfileModifier.sh · build.yml)`);
    else out.push(`‼️ pins DRIFT — gitnexus: PINS.md=${vPins ?? "?"} · DockerfileModifier.sh=${vDfm ?? "?"} · build.yml=${vBy ?? "?"} (3-place edit rule; warn-only, does not close the gate)`);
    for (const key of ["BASE_IMAGE", "HAPROXY_IMAGE"]) {
      const val = (by.match(new RegExp(`${key}:\\s*"([^"]+)"`)) || [])[1];
      if (!val) { out.push(`○  pins ${key} not found in build.yml (format changed?)`); continue; }
      const where = [!dfm.includes(val) && "DockerfileModifier.sh", !pins.includes(val) && "PINS.md"].filter(Boolean);
      out.push(where.length === 0 ? `✅ pins ${key} digest agrees ×3` : `‼️ pins DRIFT — build.yml ${key} not found in: ${where.join(" + ")} (warn-only)`);
    }
  }
} catch (e) { out.push(`○  pins check skipped (${String(e.message).split("\n")[0]})`); }

const required = cap.mcp?.required ?? [];
const direct = (cap.mcp?.directMcps ?? []).map((m) => m.name);
out.push(`◐  mcp  VERIFY against your tools — required: ${required.join(", ") || "(none)"}  ·  direct: ${direct.join(", ") || "(none)"}`);

const okFile = join(STATE, "preflight-ok");
if (requiredOk) { writeFileSync(okFile, session); out.push(`→ required capabilities present · edit/commit gate OPEN${missingWatched ? ` · ‼️ ${missingWatched} watched secret(s) missing — surface to the user` : ""}`); }
else { if (existsSync(okFile)) rmSync(okFile); out.push("→ a REQUIRED capability is missing · edit/commit gate CLOSED until fixed"); }

console.log(out.join("\n"));
process.exit(requiredOk ? 0 : 1);
