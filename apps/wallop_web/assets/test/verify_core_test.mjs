// Tests for the proof page's browser check (assets/js/verify_core.js),
// run against the vendored wallop_verifier WASM and the spec vectors.
//
//   node apps/wallop_web/assets/test/verify_core_test.mjs
//
// Node built-ins only: no npm install. VERIFY_CORE=<path> runs the same
// tests against another copy of verify_core.js (to check a broken copy
// fails).
import fs from "node:fs"
import path from "node:path"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, "../../../..")
const WASM_DIR = path.join(ROOT, "apps/wallop_web/priv/static/assets/wasm")
const VECTORS = path.join(ROOT, "spec/vectors")
const CORE = process.env.VERIFY_CORE || path.join(ROOT, "apps/wallop_web/assets/js/verify_core.js")

const wasm = await import(path.join(WASM_DIR, "wallop_verifier.js"))
wasm.initSync({ module: fs.readFileSync(path.join(WASM_DIR, "wallop_verifier_bg.wasm")) })
// The assets package is CommonJS and verify_core.js has no imports, so
// load its exact source as an ES module.
const core = await import("data:text/javascript;base64," + fs.readFileSync(CORE).toString("base64"))

const readText = f => fs.readFileSync(path.join(VECTORS, f), "utf8")
const read = f => JSON.parse(readText(f))
const V6KEYS = read("proof-bundle-v6.json").keys

let passed = 0
let failed = 0
async function t(name, fn) {
  try {
    await fn()
    passed++
    console.log("ok   ", name)
  } catch (e) {
    failed++
    console.log("FAIL ", name, "\n      " + String(e.message).split("\n").join("\n      "))
  }
}

// What the page would carry for this bundle (its data-* attributes).
function pageFor(bundleJson, keys, { receipts = true } = {}) {
  const b = JSON.parse(bundleJson)
  const lock = JSON.parse(b.lock_receipt.payload_jcs)
  const exec = JSON.parse(b.execution_receipt.payload_jcs)
  const op = keys.find(k => k.key_class === "operator")
  const infra = keys.find(k => k.key_class === "infrastructure")
  const d = {
    drawId: b.draw_id,
    entryCount: String(b.entries.length),
    entryHashFull: lock.entry_hash,
    seedFull: exec.seed,
    drandRound: String(exec.drand_round),
    drandRandomness: exec.drand_randomness,
    weatherValue: (b.entropy && b.entropy.weather_value) || "",
    winnerCount: String(b.results.length),
    entriesJson: JSON.stringify(b.entries),
    resultsJson: JSON.stringify(b.results),
    bundleUrl: "/proof/x/json",
    operatorKeysUrl: "/operator/s/keys",
    infraKeysUrl: "/infrastructure/keys"
  }
  if (receipts) {
    Object.assign(d, {
      lockReceiptJcs: b.lock_receipt.payload_jcs,
      lockSignatureHex: b.lock_receipt.signature_hex,
      operatorPublicKeyHex: op.public_key_hex,
      executionReceiptJcs: b.execution_receipt.payload_jcs,
      executionSignatureHex: b.execution_receipt.signature_hex,
      infraPublicKeyHex: infra.public_key_hex
    })
  }
  return d
}
const published = (bundleJson, keys) => ({ bundleJson, keys })
const statuses = r => r.lines.map(l => `${l.id}:${l.status}`).join(" ")
const noPass = r => assert.ok(!r.lines.some(l => l.status === "pass"), "a line shows pass: " + statuses(r))
const allPass = r => assert.ok(r.lines.every(l => l.status === "pass"), statuses(r))
const flipFirst = hex => (hex[0] === "a" ? "b" : "a") + hex.slice(1)

const FORECAST = [
  ["proof-bundle.json", readText("proof-bundle.json")],
  ["proof-bundle-drand-only.json", readText("proof-bundle-drand-only.json")]
]
const ALL_LINES = ["entry_hash", "seed", "draw", "winners", "lock_signature", "lock_binding",
                   "exec_signature", "chain", "results_binding", "drand", "gate"]

// --- forecast draws: green, and nothing else can be ---
for (const [name, bj] of FORECAST) {
  await t(`forecast ${name}: green, every line passes, drand line present`, () => {
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(bj, V6KEYS))
    assert.equal(r.gate, true)
    assert.equal(r.verdict, "green")
    allPass(r)
    assert.deepEqual(r.lines.map(l => l.id), ALL_LINES)
    assert.equal(r.bmrsYear, null)
  })
  await t(`forecast ${name}: one byte changed in the fetched bundle -> red, no line passes`, () => {
    const b = JSON.parse(bj)
    b.execution_receipt.signature_hex = flipFirst(b.execution_receipt.signature_hex)
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(JSON.stringify(b), V6KEYS))
    assert.equal(r.gate, false)
    assert.equal(r.verdict, "red")
    noPass(r)
  })
  await t(`forecast ${name}: operator key not published -> red`, () => {
    const keys = V6KEYS.filter(k => k.key_class !== "operator")
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(bj, keys))
    assert.equal(r.verdict, "red")
    noPass(r)
  })
  await t(`forecast ${name}: revoked keys, absent from the page and the endpoints -> red`, () => {
    const d = pageFor(bj, V6KEYS)
    delete d.operatorPublicKeyHex
    delete d.infraPublicKeyHex
    const r = core.computeChecks(wasm, d, published(bj, []))
    assert.equal(r.verdict, "red")
    noPass(r)
  })
  await t(`forecast ${name}: page without receipts -> amber, every line "unsigned"`, () => {
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS, { receipts: false }), null)
    assert.equal(r.verdict, "amber")
    noPass(r)
    assert.ok(r.lines.every(l => l.status === "unsigned"), statuses(r))
  })
  await t(`forecast ${name}: page seed differs from the signed one -> red`, () => {
    const d = pageFor(bj, V6KEYS)
    d.seedFull = "00" + d.seedFull.slice(2)
    assert.equal(core.computeChecks(wasm, d, published(bj, V6KEYS)).verdict, "red")
  })
}

await t("forecast fallback label, only when the receipt names a reason", () => {
  const bj = FORECAST[1][1]
  const exec = JSON.parse(JSON.parse(bj).execution_receipt.payload_jcs)
  assert.ok(exec.weather_fallback_reason, "the drand-only vector names a reason")
  const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(bj, V6KEYS))
  assert.equal(r.fallbackLabel,
    "Weather data wasn't available for this draw, so the seed came from drand's public randomness " +
    `beacon alone (reason: ${exec.weather_fallback_reason})`)
  const w = core.computeChecks(wasm, pageFor(FORECAST[0][1], V6KEYS), published(FORECAST[0][1], V6KEYS))
  assert.equal(w.fallbackLabel, null)
})

// --- lock v6 / execution v5: the signed receipt picks the formula ---
const V6 = {
  "proof-bundle-v6.json": { formula: "weather", label: null, bmrs: false },
  "proof-bundle-v6-freq-window.json": {
    formula: "frequency",
    label: "Middle Wallop's reading was running late, so this draw listened to the hum of the National Grid instead.",
    bmrs: true
  },
  "proof-bundle-v6-fallback.json": {
    formula: "drand_only",
    label: "Middle Wallop was late and the Grid went quiet, so drand did this one on its own.",
    bmrs: false
  },
  "proof-bundle-v6-freq.json": { formula: "frequency", label: null, bmrs: true },
  "proof-bundle-v6-freq-fallback.json": {
    formula: "drand_only", label: "The Grid went quiet, so drand did this one on its own.", bmrs: false
  }
}
for (const [f, want] of Object.entries(V6)) {
  await t(`v6 ${f}: green via ${want.formula}`, () => {
    const v = read(f)
    const d = pageFor(v.bundle, v.keys)
    const exec = JSON.parse(JSON.parse(v.bundle).execution_receipt.payload_jcs)
    d.weatherValue = exec.weather_value || ""
    const r = core.computeChecks(wasm, d, published(v.bundle, v.keys))
    assert.equal(r.verdict, "green", statuses(r))
    allPass(r)
    assert.equal(r.formula, want.formula)
    assert.equal(r.fallbackLabel, want.label)
    assert.equal(r.bmrsYear !== null, want.bmrs)
  })
}
await t("v6 frequency draw with a stale weather value on the page still uses the signed formula", () => {
  const v = read("proof-bundle-v6-freq-window.json")
  const d = pageFor(v.bundle, v.keys)
  d.weatherValue = "1234"
  const r = core.computeChecks(wasm, d, published(v.bundle, v.keys))
  assert.equal(r.verdict, "green")
  assert.equal(r.formula, "frequency")
})

const NEG = read("proof-bundle-v6-negative.json")

// --- observation weather: what each state shows ---
const LANDOBS_LINES = ["entry_hash", "seed", "draw", "winners", "lock_signature", "lock_binding",
                       "exec_signature", "chain", "results_binding", "drand", "observation_hour", "gate"]
const landobs = f => {
  const v = read(f)
  const d = pageFor(v.bundle, v.keys)
  const exec = JSON.parse(JSON.parse(v.bundle).execution_receipt.payload_jcs)
  d.weatherValue = exec.weather_value || ""
  return { v, d, r: core.computeChecks(wasm, d, published(v.bundle, v.keys)) }
}
await t("observationHour: round 33068212 (published 20:00Z) observes 19:00Z, as the lock receipt writes it", () => {
  assert.equal(core.observationHour(33068212), "2026-10-14T19:00:00.000000Z")
  // One round earlier publishes 19:59:57, past 19:00 + W + 60s: still 19:00.
  assert.equal(core.observationHour(33068211), "2026-10-14T19:00:00.000000Z")
  // pub 19:31:00 is exactly 19:00 + W + 60s; one round earlier is 18:00.
  assert.equal(core.observationHour(33068212 - 580), "2026-10-14T19:00:00.000000Z")
  assert.equal(core.observationHour(33068212 - 581), "2026-10-14T18:00:00.000000Z")
})
await t("state (a): weather, no fallback label, no BMRS, hour line passes with 19:00 UTC", () => {
  const { r } = landobs("proof-bundle-v6.json")
  assert.equal(r.verdict, "green")
  assert.deepEqual(r.lines.map(l => l.id), LANDOBS_LINES)
  allPass(r)
  assert.equal(r.formula, "weather")
  assert.equal(r.fallbackLabel, null)
  assert.equal(r.bmrsYear, null)
  assert.equal(r.lines.find(l => l.id === "observation_hour").passLabel, "19:00 UTC")
  assert.match(r.lines.find(l => l.id === "seed").text, /wx\[123;1012;67;3450\]/)
})
await t("state (b): grid frequency, the approved label naming the Grid, BMRS for the readings' year", () => {
  const { r } = landobs("proof-bundle-v6-freq-window.json")
  assert.equal(r.verdict, "green")
  assert.deepEqual(r.lines.map(l => l.id), LANDOBS_LINES)
  assert.equal(r.formula, "frequency")
  assert.equal(r.fallbackLabel, core.LANDOBS_FREQUENCY_LABEL)
  assert.equal(r.bmrsYear, "2026")
  assert.match(r.lines.find(l => l.id === "seed").text, /grid\[8 readings\]/)
})
await t("state (c): drand alone, the approved label naming drand, no BMRS", () => {
  const { r } = landobs("proof-bundle-v6-fallback.json")
  assert.equal(r.verdict, "green")
  assert.deepEqual(r.lines.map(l => l.id), LANDOBS_LINES)
  assert.equal(r.formula, "drand_only")
  assert.equal(r.fallbackLabel, core.LANDOBS_DRAND_ONLY_LABEL)
  assert.equal(r.bmrsYear, null)
  assert.equal(r.lines.find(l => l.id === "seed").text, "seed = SHA256(hash, drand[33068212]) → ")
})
await t("observation states shown only behind the gate: a gate refusal leaves no tick and no label", () => {
  for (const f of ["proof-bundle-v6.json", "proof-bundle-v6-freq-window.json", "proof-bundle-v6-fallback.json"]) {
    const v = read(f)
    const b = JSON.parse(v.bundle)
    b.lock_receipt.signature_hex = flipFirst(b.lock_receipt.signature_hex)
    const d = pageFor(v.bundle, v.keys)
    const r = core.computeChecks(wasm, d, published(JSON.stringify(b), v.keys))
    assert.equal(r.verdict, "red", f)
    noPass(r)
    const hour = r.lines.find(l => l.id === "observation_hour")
    assert.ok(hour && hour.status === "unconfirmed", statuses(r))
  }
})
await t("a signed hour the round doesn't imply fails the hour line itself, not only the gate", () => {
  const c = NEG.cases.find(x => x.name === "weather_time_not_derived_from_round")
  assert.ok(c, "case present")
  const r = core.computeChecks(wasm, pageFor(c.bundle, NEG.keys), published(c.bundle, NEG.keys))
  assert.equal(r.verdict, "red")
  const hour = r.lines.find(l => l.id === "observation_hour")
  assert.ok(hour && hour.status === "fail", statuses(r))
  noPass(r)
})
await t("the BMRS year is the signed window start T's, not the execution time's", () => {
  const v = read("proof-bundle-v6-freq-window.json")
  const b = JSON.parse(v.bundle)
  const lock = JSON.parse(b.lock_receipt.payload_jcs)
  lock.freq_start = "2025-12-31T23:54:00.000000Z"
  b.lock_receipt.payload_jcs = JSON.stringify(lock)
  const bj = JSON.stringify(b)
  const d = pageFor(bj, v.keys)
  const r = core.computeChecks(wasm, d, published(bj, v.keys))
  // The edit breaks the signature, so it is red; the year still follows T.
  assert.equal(r.verdict, "red")
  assert.equal(r.bmrsYear, "2025")
})
await t("grid-frequency tag outside its two states: seed line fails, no label, no BMRS", () => {
  const base = read("proof-bundle-v6-freq.json")
  const fb = read("proof-bundle-v6-freq-fallback.json")
  const edits = [
    [base, e => { e.freq_fallback_reason = "no_frequency_by_deadline" }],
    [fb, e => { e.freq_fallback_reason = null }],
    [base, e => { e.weather_station = "wmo-03749" }],
    [base, e => { delete e.weather_fallback_reason }]
  ]
  for (const [v, edit] of edits) {
    const b = JSON.parse(v.bundle)
    const exec = JSON.parse(b.execution_receipt.payload_jcs)
    edit(exec)
    b.execution_receipt.payload_jcs = JSON.stringify(exec)
    const bj = JSON.stringify(b)
    const r = core.computeChecks(wasm, pageFor(bj, v.keys), published(bj, v.keys))
    assert.equal(r.verdict, "red")
    const seed = r.lines.find(l => l.id === "seed")
    assert.ok(seed && seed.status === "fail", statuses(r))
    assert.equal(r.fallbackLabel, null)
    assert.equal(r.bmrsYear, null)
    noPass(r)
  }
})
await t("forecast and grid-frequency-tag draws have no observation hour line", () => {
  for (const bj of [FORECAST[0][1], read("proof-bundle-v6-freq.json").bundle]) {
    const keys = bj === FORECAST[0][1] ? V6KEYS : read("proof-bundle-v6-freq.json").keys
    const r = core.computeChecks(wasm, pageFor(bj, keys), published(bj, keys))
    assert.equal(r.verdict, "green")
    assert.ok(!r.lines.some(l => l.id === "observation_hour"), statuses(r))
  }
})

await t(`v6 negative: all ${NEG.cases.length} cases red, no line passes`, () => {
  for (const c of NEG.cases) {
    const r = core.computeChecks(wasm, pageFor(c.bundle, NEG.keys), published(c.bundle, NEG.keys))
    assert.equal(r.verdict, "red", c.name)
    noPass(r)
  }
})
await t("v6 out of the three-state table (weather value plus freq_value): seed line fails", () => {
  const c = NEG.cases.find(x => x.name === "weather_with_freq_value")
  assert.ok(c, "case present")
  const r = core.computeChecks(wasm, pageFor(c.bundle, NEG.keys), published(c.bundle, NEG.keys))
  assert.equal(r.verdict, "red")
  const seed = r.lines.find(l => l.id === "seed")
  assert.ok(seed && seed.status === "fail", statuses(r))
  // No source is named and no seed formula is claimed.
  assert.equal(r.fallbackLabel, null)
  assert.equal(r.formula, null)
  assert.equal(r.bmrsYear, null)
  assert.equal(seed.text, "seed = SHA256(hash, drand[33068212], ?) → ")
  noPass(r)
})
for (const f of ["proof-bundle-v6-tamper.json", "proof-bundle-v6-tamper-freq.json"]) {
  const tv = read(f)
  await t(`${f}: all ${tv.cases.length} cases red with no line passing; bases green`, () => {
    for (const c of tv.cases) {
      const r = core.computeChecks(wasm, pageFor(c.bundle, tv.keys), published(c.bundle, tv.keys))
      assert.equal(r.verdict, "red", c.name)
      noPass(r)
    }
    for (const b of tv.bases) {
      const r = core.computeChecks(wasm, pageFor(b.bundle, tv.keys), published(b.bundle, tv.keys))
      assert.equal(r.verdict, "green", b.name)
    }
  })
}

// --- the verdict table and fetching ---
await t("finalVerdict table", () => {
  assert.equal(core.finalVerdict({ gate: true, linesPassed: true, hasReceipts: true }), "green")
  assert.equal(core.finalVerdict({ gate: false, linesPassed: true, hasReceipts: true }), "red")
  assert.equal(core.finalVerdict({ gate: true, linesPassed: false, hasReceipts: true }), "red")
  assert.equal(core.finalVerdict({ gate: null, linesPassed: true, hasReceipts: false }), "amber")
  assert.equal(core.finalVerdict({ gate: null, linesPassed: false, hasReceipts: false }), "red")
  assert.equal(core.finalVerdict({ gate: "yes", linesPassed: true, hasReceipts: true }), "red")
})

const response = (status, body) => ({
  ok: status >= 200 && status < 300, status, text: async () => body, json: async () => JSON.parse(body)
})
const URLS = { bundleUrl: "/b", operatorKeysUrl: "/o", infraKeysUrl: "/i" }
await t("fetchPublishedProof keeps the bundle bytes and maps both key lists", async () => {
  const bundle = FORECAST[0][1]
  const routes = {
    "/b": response(200, bundle),
    "/o": response(200, JSON.stringify({ schema_version: "1", keys: [{ key_id: "a", key_class: "operator", public_key_hex: "aa", inserted_at: "t", extra: 1 }] })),
    "/i": response(200, JSON.stringify({ schema_version: "1", keys: [{ key_id: "b", key_class: "infrastructure", public_key_hex: "bb", inserted_at: "u" }] }))
  }
  const p = await core.fetchPublishedProof(URLS, async u => routes[u])
  assert.equal(p.bundleJson, bundle)
  assert.deepEqual(p.keys, [
    { key_id: "a", key_class: "operator", public_key_hex: "aa", inserted_at: "t" },
    { key_id: "b", key_class: "infrastructure", public_key_hex: "bb", inserted_at: "u" }
  ])
})
await t("fetchPublishedProof: no answer is 'network'; a non-2xx, unreadable keys or a missing URL is 'refused'", async () => {
  await assert.rejects(core.fetchPublishedProof(URLS, async () => { throw new TypeError("Failed to fetch") }),
    e => e.kind === "network")
  const ok = response(200, JSON.stringify({ keys: [] }))
  const refused = response(500, JSON.stringify({ error: "proof_chain_incomplete" }))
  await assert.rejects(core.fetchPublishedProof(URLS, async u => (u === "/b" ? refused : ok)), e => e.kind === "refused")
  const badKeys = { ok: true, status: 200, text: async () => "{}", json: async () => { throw new SyntaxError("x") } }
  await assert.rejects(core.fetchPublishedProof(URLS, async () => badKeys), e => e.kind === "refused")
  await assert.rejects(core.fetchPublishedProof({ bundleUrl: "/b" }, async () => ok), e => e.kind === "refused")
})

// --- every ticked line is tied to the published bytes ---
{
  const bj = FORECAST[0][1]
  const otherB = JSON.parse(FORECAST[1][1])
  await t("a self-consistent page from another draw, beside a valid published bundle -> red", () => {
    const r = core.computeChecks(wasm, pageFor(FORECAST[1][1], V6KEYS), published(bj, V6KEYS))
    assert.equal(r.verdict, "red")
    noPass(r)
    assert.ok(r.bindingProblem)
  })
  const mutations = {
    drawId: d => { d.drawId = "00000000-0000-4000-8000-000000000000" },
    lockReceiptJcs: d => { d.lockReceiptJcs = otherB.lock_receipt.payload_jcs },
    lockSignatureHex: d => { d.lockSignatureHex = otherB.lock_receipt.signature_hex },
    executionReceiptJcs: d => { d.executionReceiptJcs = otherB.execution_receipt.payload_jcs },
    executionSignatureHex: d => { d.executionSignatureHex = otherB.execution_receipt.signature_hex },
    entriesJson: d => { const e = JSON.parse(d.entriesJson); e[0].weight = 2; d.entriesJson = JSON.stringify(e) },
    resultsJson: d => {
      const r = JSON.parse(d.resultsJson)
      ;[r[0].entry_id, r[1].entry_id] = [r[1].entry_id, r[0].entry_id]
      d.resultsJson = JSON.stringify(r)
    },
    operatorPublicKeyHex: d => { d.operatorPublicKeyHex = d.infraPublicKeyHex },
    infraPublicKeyHex: d => { d.infraPublicKeyHex = d.operatorPublicKeyHex },
    entryCount: d => { d.entryCount = String(Number(d.entryCount) + 1) },
    winnerCount: d => { d.winnerCount = String(Number(d.winnerCount) + 1) },
    drandRound: d => { d.drandRound = String(Number(d.drandRound) + 1) }
  }
  for (const [k, mutate] of Object.entries(mutations)) {
    await t(`page ${k} differs from the published bundle or keys -> red, no line passes`, () => {
      const d = pageFor(bj, V6KEYS)
      mutate(d)
      const r = core.computeChecks(wasm, d, published(bj, V6KEYS))
      assert.equal(r.verdict, "red")
      noPass(r)
    })
  }
  await t("page lists the entries in another order -> still green", () => {
    const d = pageFor(bj, V6KEYS)
    d.entriesJson = JSON.stringify(JSON.parse(d.entriesJson).reverse())
    assert.equal(core.computeChecks(wasm, d, published(bj, V6KEYS)).verdict, "green")
  })
  await t("drand line rests on the signed lock time", () => {
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(bj, V6KEYS))
    assert.equal(r.lines.find(l => l.id === "drand").passLabel, "genuine, published after the signed lock time")
  })

  // --- partial receipts go to the published proof, never amber ---
  const partial = () => {
    const d = pageFor(bj, V6KEYS)
    delete d.executionReceiptJcs
    delete d.executionSignatureHex
    delete d.infraPublicKeyHex
    return d
  }
  await t("receiptState: full, partial, none; a public key alone is not a receipt", () => {
    assert.equal(core.receiptState(pageFor(bj, V6KEYS)), "full")
    assert.equal(core.receiptState(partial()), "partial")
    const keysOnly = pageFor(bj, V6KEYS, { receipts: false })
    keysOnly.operatorPublicKeyHex = "aa"
    assert.equal(core.receiptState(keysOnly), "none")
  })
  await t("partial receipts and the site refuses the bundle -> red with the refused text", () => {
    const r = core.computeChecks(wasm, partial(), null)
    assert.equal(r.verdict, "red")
    assert.equal(r.fatal, core.REFUSED_RED)
  })
  await t("partial receipts but the site serves a valid bundle -> red, no line passes", () => {
    const r = core.computeChecks(wasm, partial(), published(bj, V6KEYS))
    assert.equal(r.verdict, "red")
    noPass(r)
    assert.equal(r.lines.at(-1).id, "gate")
    assert.equal(r.lines.at(-1).status, "fail")
  })
}

// --- a refused or unreadable bundle has its own red ---
{
  const bj = FORECAST[0][1]
  await t("the refused text is distinct from the generic red", () => {
    assert.equal(core.REFUSED_RED,
      "FAILED — this site couldn't produce a complete proof for this draw, so it can't be verified. " +
      "Please tell the organiser, and don't rely on this result.")
    assert.notEqual(core.REFUSED_RED, core.GENERIC_RED)
  })
  await t("unreadable bundle -> red with the refused text, no lines", () => {
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(bj.slice(0, -1), V6KEYS))
    assert.equal(r.verdict, "red")
    assert.equal(r.fatal, core.REFUSED_RED)
    assert.equal(r.lines.length, 0)
  })
  await t("an error body instead of a bundle -> red with the refused text", () => {
    const body = '{"error":"proof_chain_incomplete","detail":"missing_execution_receipt"}'
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(body, V6KEYS))
    assert.equal(r.verdict, "red")
    assert.equal(r.fatal, core.REFUSED_RED)
  })
  await t("full receipts and nothing published -> red with the refused text", () => {
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), null)
    assert.equal(r.verdict, "red")
    assert.equal(r.fatal, core.REFUSED_RED)
  })
  await t("a gate refusal uses the generic red", () => {
    const b = JSON.parse(bj)
    b.lock_receipt.signature_hex = flipFirst(b.lock_receipt.signature_hex)
    const r = core.computeChecks(wasm, pageFor(bj, V6KEYS), published(JSON.stringify(b), V6KEYS))
    assert.equal(r.verdict, "red")
    assert.equal(r.fatal, null)
    assert.equal(r.lines.at(-1).failMessage, core.GENERIC_RED)
  })
}

console.log(`\n${passed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
