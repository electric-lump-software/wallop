/**
 * What the proof page's verify block checks, with no DOM and no animation.
 *
 * `computeChecks` decides every line and the final colour up front; the
 * runner in verify.js only animates the result. Keeping the decisions
 * here means they can be run against the WASM verifier and the spec
 * vectors outside a browser.
 *
 * The rule the page lives by: green, amber or red is decided by
 * `verify_bundle_with_resolved_keys_wasm` in attestable mode, over the
 * bundle exactly as /proof/:id/json serves it and the keys the site
 * publishes. No line shows a pass that the gate has not backed.
 */

export const LANDOBS_TAG = "drand-quicknet+metoffice-landobs-v1"
export const FREQ_TAG = "drand-quicknet+elexon-freq-v1"

// Execution receipt schema that carries the two lock-v6 tags. Any other
// tag on it is unknown to this page.
const V6_EXEC_SCHEMA = "5"

// serde_wasm_bindgen may return a Map instead of a plain object.
const field = (value, key) => (value instanceof Map ? value.get(key) : value[key])

export function hasReceipts(d) {
  return !!(d.lockReceiptJcs && d.lockSignatureHex && d.operatorPublicKeyHex &&
            d.executionReceiptJcs && d.executionSignatureHex && d.infraPublicKeyHex)
}

/** Map a `/operator/:slug/keys` or `/infrastructure/keys` body to the rows the WASM expects. */
export function keyRows(body) {
  const keys = body && Array.isArray(body.keys) ? body.keys : []
  return keys.map(k => ({
    key_id: k.key_id,
    key_class: k.key_class,
    public_key_hex: k.public_key_hex,
    inserted_at: k.inserted_at
  }))
}

/**
 * Fetch the published bundle (its bytes, untouched) and the published
 * operator and infrastructure keys. Throws on anything short of three
 * successful responses: a refused bundle is never treated as checkable.
 */
export async function fetchPublishedProof(d, fetchImpl = url => fetch(url)) {
  if (!d.bundleUrl || !d.operatorKeysUrl || !d.infraKeysUrl) {
    throw new Error("this page does not say where its proof is published")
  }
  const [bundleRes, opRes, infraRes] = await Promise.all([
    fetchImpl(d.bundleUrl), fetchImpl(d.operatorKeysUrl), fetchImpl(d.infraKeysUrl)
  ])
  if (!bundleRes.ok || !opRes.ok || !infraRes.ok) {
    throw new Error("the bundle or the keys could not be fetched")
  }
  const bundleJson = await bundleRes.text()
  return { bundleJson, keys: [...keyRows(await opRes.json()), ...keyRows(await infraRes.json())] }
}

/** The gate. Anything but a plain `true` (including a throw) is a refusal. */
export function runGate(wasm, bundleJson, keys) {
  try {
    return wasm.verify_bundle_with_resolved_keys_wasm(bundleJson, keys, "attestable") === true
  } catch (_e) {
    return false
  }
}

export function finalVerdict({ gate, linesPassed, hasReceipts }) {
  if (!linesPassed) return "red"
  if (!hasReceipts) return "amber"
  return gate === true ? "green" : "red"
}

/**
 * Which seed formula the draw used, read from the signed execution
 * receipt, never from which value happens to be on the page.
 *
 * - Observation weather tag: `landobs_exec_state_wasm` names the state.
 * - Grid-frequency tag: the frequency value, or drand alone when null.
 * - Forecast and older receipts: the page's existing path.
 *
 * Throws when the receipt fits none of these.
 */
export function seedPlan(wasm, exec, execJcs, d) {
  const page = formula => ({
    formula,
    value: formula === "weather" ? d.weatherValue : null,
    randomness: d.drandRandomness,
    fallbackLabel: null
  })

  if (!exec) return page(d.weatherValue ? "weather" : "drand_only")

  const tag = exec.entropy_composition
  const signed = (formula, value, fallbackLabel = null) =>
    ({ formula, value, randomness: exec.drand_randomness, fallbackLabel })

  if (tag === LANDOBS_TAG) {
    const state = wasm.landobs_exec_state_wasm(execJcs)
    if (state === "weather") return signed("weather", exec.weather_value)
    if (state === "frequency") {
      return signed("frequency", exec.freq_value,
        `grid frequency (weather fallback: ${exec.weather_fallback_reason})`)
    }
    if (state === "drand_only") {
      return signed("drand_only", null,
        `drand only (weather fallback: ${exec.weather_fallback_reason}; ` +
        `grid frequency fallback: ${exec.freq_fallback_reason})`)
    }
    throw new Error(`unknown observation state: ${state}`)
  }

  if (tag === FREQ_TAG) {
    if (exec.weather_value != null) throw new Error("a grid-frequency receipt carries a weather value")
    if (typeof exec.freq_value === "string") return signed("frequency", exec.freq_value)
    if (exec.freq_value === null) {
      return signed("drand_only", null, `drand only (grid frequency fallback: ${exec.freq_fallback_reason})`)
    }
    throw new Error("freq_value is neither a string nor null")
  }

  if (exec.schema_version === V6_EXEC_SCHEMA) throw new Error(`unknown entropy tag: ${tag}`)

  // Forecast and older receipts keep the existing path.
  const plan = page(d.weatherValue ? "weather" : "drand_only")
  if (plan.formula === "drand_only" && exec.weather_fallback_reason) {
    plan.fallbackLabel = `drand only (weather fallback: ${exec.weather_fallback_reason})`
  }
  return plan
}

function seedText(plan, round) {
  if (!plan) return `seed = SHA256(hash, drand[${round}], ?) → `
  if (plan.formula === "weather") return `seed = SHA256(hash, drand[${round}], wx[${plan.value}]) → `
  if (plan.formula === "frequency") {
    return `seed = SHA256(hash, drand[${round}], grid[${plan.value.split(";").length} readings]) → `
  }
  return `seed = SHA256(hash, drand[${round}]) → `
}

function computeSeed(wasm, plan, entryHash) {
  let r
  if (plan.formula === "weather") r = wasm.compute_seed_wasm(entryHash, plan.randomness, plan.value)
  else if (plan.formula === "frequency") r = wasm.compute_seed_freq_wasm(entryHash, plan.randomness, plan.value)
  else r = wasm.compute_seed_drand_only_wasm(entryHash, plan.randomness)
  return field(r, "seed")
}

function verifyWinners(wasm, plan, d, entries, expected, count) {
  if (plan.formula === "frequency") {
    return wasm.verify_freq_wasm(d.drawId, entries, plan.randomness, plan.value, count, expected)
  }
  return wasm.verify_wasm(d.drawId, entries, plan.randomness, plan.value || undefined, count, expected)
}

/**
 * Decide every line and the verdict.
 *
 * `published` is `{bundleJson, keys}` from `fetchPublishedProof`, or null
 * when nothing was fetched. A page with receipts and no published proof
 * is red.
 *
 * Each line has a `status`:
 * - "pass": its own check held and the gate passed;
 * - "unconfirmed": its own check held but the gate refused the bundle;
 * - "unsigned": its own check held on a page with no receipts (no gate);
 * - "fail": its own check failed. Lines stop at the first failure.
 */
export function computeChecks(wasm, d, published) {
  const receipts = hasReceipts(d)
  const result = {
    hasReceipts: receipts, gate: null, lines: [], verdict: null, fatal: null,
    formula: null, fallbackLabel: null, bmrsYear: null
  }
  const refuse = message => {
    result.gate = false
    result.fatal = message
    result.verdict = "red"
    return result
  }

  let exec = null
  let execJcs = null
  if (receipts) {
    if (!published) return refuse("FAILED — could not fetch the published proof bundle and keys")
    try {
      execJcs = JSON.parse(published.bundleJson).execution_receipt.payload_jcs
      exec = JSON.parse(execJcs)
    } catch (_e) {
      return refuse("FAILED — the published proof bundle could not be read")
    }
    result.gate = runGate(wasm, published.bundleJson, published.keys)
  }

  const lines = result.lines
  const statusFor = ok => {
    if (!ok) return "fail"
    if (!receipts) return "unsigned"
    return result.gate === true ? "pass" : "unconfirmed"
  }
  const settle = (line, ok, failMessage) => {
    line.ok = ok
    line.status = statusFor(ok)
    if (!ok) line.failMessage = failMessage
    lines.push(line)
    return ok
  }
  const done = () => {
    result.verdict = finalVerdict({ gate: result.gate, linesPassed: lines.every(l => l.ok), hasReceipts: receipts })
    return result
  }
  // Run one check; a throw fails the line with `errorPrefix: message`.
  const check = (line, mismatch, errorPrefix, fn) => {
    let ok
    try {
      ok = fn() === true
    } catch (e) {
      return settle(line, false, `${errorPrefix}: ${e && e.message ? e.message : e}`)
    }
    return settle(line, ok, mismatch)
  }

  let entries
  let computedEntryHash

  // entry_hash, recomputed from the entries
  const entryLine = { id: "entry_hash", text: `entry_hash = SHA256(${d.entryCount} entries) → `,
                      waitLabel: "match", passLabel: "match", mono: null, scrambleMs: 1200 }
  if (!check(entryLine, "MISMATCH — computed entry_hash does not match stored value", "Entry hash computation error", () => {
    entries = JSON.parse(d.entriesJson).map(e => ({ id: e.uuid, weight: e.weight }))
    computedEntryHash = field(wasm.entry_hash_wasm(d.drawId, entries), "hash")
    entryLine.mono = computedEntryHash.substring(0, 8)
    return computedEntryHash === d.entryHashFull
  })) return done()

  // seed, by the formula the signed receipt names
  let plan = null
  const seedLine = { id: "seed", text: null, waitLabel: "match", passLabel: "match", mono: null,
                     scrambleMs: 1200, typeSpeed: 20 }
  const seedOk = check(seedLine, "MISMATCH — computed seed does not match stored value", "Seed computation error", () => {
    plan = seedPlan(wasm, exec, execJcs, d)
    seedLine.text = seedText(plan, d.drandRound)
    const seed = computeSeed(wasm, plan, computedEntryHash)
    seedLine.mono = seed.substring(0, 8)
    return seed === d.seedFull
  })
  if (!seedLine.text) seedLine.text = seedText(null, d.drandRound)
  if (!seedOk) return done()
  result.formula = plan.formula
  result.fallbackLabel = plan.fallbackLabel
  if (plan.formula === "frequency") {
    const year = exec && typeof exec.executed_at === "string" ? exec.executed_at.substring(0, 4) : ""
    result.bmrsYear = year || String(new Date().getUTCFullYear())
  }

  // the draw itself (shown as a count; the next line checks it)
  settle({ id: "draw", kind: "count", count: d.entryCount, mono: `${d.winnerCount} winners`,
           text: `winners = fair_pick.draw(${d.entryCount} entries, seed, ${d.winnerCount}) → `,
           waitLabel: "selected", passLabel: "selected", typeSpeed: 20 }, true)

  if (!check({ id: "winners", text: "assert winners == stored_results → ", passLabel: "match" },
             "MISMATCH — draw math verification failed", "Verification error", () =>
    verifyWinners(wasm, plan, d, entries, JSON.parse(d.resultsJson), parseInt(d.winnerCount)))) return done()

  if (!receipts) return done()

  const lockSig = { id: "lock_signature", text: "verify lock receipt (Ed25519) → ",
                    waitLabel: "valid signature", passLabel: "valid signature", mono: null, scrambleMs: 600 }
  if (!check(lockSig, "FAILED — lock receipt signature invalid", "Lock receipt verification error", () => {
    lockSig.mono = wasm.key_id_wasm(d.operatorPublicKeyHex)
    return wasm.verify_receipt_wasm(d.lockReceiptJcs, d.lockSignatureHex, d.operatorPublicKeyHex)
  })) return done()

  if (!check({ id: "lock_binding", text: "lock receipt entry_hash binding → ", passLabel: "bound" },
             "MISMATCH — lock receipt entry_hash does not match computed hash", "Failed to parse lock receipt", () =>
    JSON.parse(d.lockReceiptJcs).entry_hash === d.entryHashFull)) return done()

  const execSig = { id: "exec_signature", text: "verify execution receipt (Ed25519) → ",
                    waitLabel: "valid signature", passLabel: "valid signature", mono: null, scrambleMs: 600 }
  if (!check(execSig, "FAILED — execution receipt signature invalid", "Execution receipt verification error", () => {
    execSig.mono = wasm.key_id_wasm(d.infraPublicKeyHex)
    return wasm.verify_receipt_wasm(d.executionReceiptJcs, d.executionSignatureHex, d.infraPublicKeyHex)
  })) return done()

  const chain = { id: "chain", text: "lock_receipt_hash chain → ", waitLabel: "chain intact",
                  passLabel: "chain intact", mono: null, scrambleMs: 800 }
  let chainMismatch = "MISMATCH — lock_receipt_hash chain is broken"
  if (!check(chain, null, "Chain verification error", () => {
    const payload = JSON.parse(d.executionReceiptJcs)
    if (payload.seed !== d.seedFull) {
      chainMismatch = "MISMATCH — execution receipt seed does not match computed seed"
      return false
    }
    const expected = wasm.lock_receipt_hash_wasm(d.lockReceiptJcs)
    chain.mono = expected.substring(0, 8)
    return payload.lock_receipt_hash === expected
  })) {
    if (!chain.failMessage) chain.failMessage = chainMismatch
    return done()
  }

  if (!check({ id: "results_binding", text: "execution receipt results binding → ", passLabel: "bound" },
             "MISMATCH — execution receipt results do not match computed results", "Results binding error", () =>
    JSON.stringify(JSON.parse(d.executionReceiptJcs).results) ===
      JSON.stringify(JSON.parse(d.resultsJson).map(r => r.entry_id)))) return done()

  // drand, from the signed execution receipt in the published bundle.
  // A line, never a gate: "published after the lock" is the gate's check.
  if (!check({ id: "drand", text: "drand beacon → ", waitLabel: "genuine, published after the lock",
               passLabel: "genuine, published after the lock" },
             "FAILED — the drand beacon did not verify", "drand check error", () =>
    wasm.verify_drand_wasm(exec.drand_chain, BigInt(exec.drand_round), exec.drand_signature, exec.drand_randomness)
  )) return done()

  settle({ id: "gate", text: "verify published proof bundle (attestable) → ", waitLabel: "passed", passLabel: "passed" },
         result.gate === true,
         "FAILED — the published proof bundle did not verify against the published keys")
  return done()
}
