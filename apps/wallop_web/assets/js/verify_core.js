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

/** The red verdict when no single line names the problem. */
export const GENERIC_RED =
  "FAILED — something in this draw's proof doesn't check out. The lines above show what. " +
  "Please tell the organiser, and don't rely on this result."

/**
 * The red verdict when the site would not produce a checkable proof (a
 * non-2xx bundle such as 500 proof_chain_incomplete, or one that can't be
 * read). No line ran, so it can't point at one.
 */
export const REFUSED_RED =
  "FAILED — this site couldn't produce a complete proof for this draw, so it can't be verified. " +
  "Please tell the organiser, and don't rely on this result."

export const LANDOBS_TAG = "drand-quicknet+metoffice-landobs-v1"

/** What an observation-weather draw says when it fell back, by the signed state. */
export const LANDOBS_FREQUENCY_LABEL =
  "Middle Wallop's reading was running late, so this draw listened to the hum of the National Grid instead."
export const LANDOBS_DRAND_ONLY_LABEL =
  "Middle Wallop was late and the Grid went quiet, so drand did this one on its own."
/** What a grid-frequency draw says when the readings didn't turn up. */
export const FREQ_DRAND_ONLY_LABEL = "The Grid went quiet, so drand did this one on its own."
const FREQ_FALLBACK_REASON = "no_frequency_by_deadline"
const FREQ_WEATHER_KEYS = ["weather_station", "weather_value", "weather_observation_time", "weather_fallback_reason"]

// drand quicknet's genesis and period, and the observation tag's fetch
// window W and slack, all frozen by the tag. Used only to show the
// observation hour; the gate does the real check.
const QUICKNET_GENESIS = 1692803367
const QUICKNET_PERIOD = 3
const LANDOBS_WINDOW_SECONDS = 30 * 60
const LANDOBS_SLACK_SECONDS = 60

/**
 * The observation hour of drand round `round`, as the lock receipt writes
 * it: the latest whole UTC hour h with h + W + 60s <= pub(round).
 */
export function observationHour(round) {
  const pub = QUICKNET_GENESIS + (Number(round) - 1) * QUICKNET_PERIOD
  const latest = pub - LANDOBS_WINDOW_SECONDS - LANDOBS_SLACK_SECONDS
  const hour = latest - (((latest % 3600) + 3600) % 3600)
  return new Date(hour * 1000).toISOString().replace(".000Z", ".000000Z")
}
export const FREQ_TAG = "drand-quicknet+elexon-freq-v1"

// The only receipt schemas this page checks: lock 6 and execution 5, under
// the two tags above. Anything else throws in seedPlan.
const V6_LOCK_SCHEMA = "6"
const V6_EXEC_SCHEMA = "5"

// serde_wasm_bindgen may return a Map instead of a plain object.
const field = (value, key) => (value instanceof Map ? value.get(key) : value[key])

const RECEIPT_ATTRS = ["lockReceiptJcs", "lockSignatureHex", "operatorPublicKeyHex",
                       "executionReceiptJcs", "executionSignatureHex", "infraPublicKeyHex"]

export function hasReceipts(d) {
  return RECEIPT_ATTRS.every(k => !!d[k])
}

/**
 * "full", "partial" (a receipt or signature is there, but not all of
 * them) or "none". A public key on its own is not a receipt.
 */
export function receiptState(d) {
  if (hasReceipts(d)) return "full"
  const receiptParts = ["lockReceiptJcs", "lockSignatureHex", "executionReceiptJcs", "executionSignatureHex"]
  return receiptParts.some(k => !!d[k]) ? "partial" : "none"
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

function fetchError(kind, message) {
  const e = new Error(message)
  e.kind = kind
  return e
}

/**
 * Fetch the published bundle (its bytes, untouched) and the published
 * operator and infrastructure keys. Throws on anything short of three
 * successful responses, with `kind`:
 *
 * - "network": a request never got an answer. Nothing was checked.
 * - "refused": the site answered but would not serve a checkable proof
 *   (a non-2xx such as 500 proof_chain_incomplete, a missing URL, or
 *   unreadable keys). That is a failure of the draw's proof, never green.
 */
export async function fetchPublishedProof(d, fetchImpl = url => fetch(url)) {
  if (!d.bundleUrl || !d.operatorKeysUrl || !d.infraKeysUrl) {
    throw fetchError("refused", "this page does not say where its proof is published")
  }
  let responses
  try {
    responses = await Promise.all([
      fetchImpl(d.bundleUrl), fetchImpl(d.operatorKeysUrl), fetchImpl(d.infraKeysUrl)
    ])
  } catch (e) {
    throw fetchError("network", e && e.message ? e.message : String(e))
  }
  const [bundleRes, opRes, infraRes] = responses
  if (!bundleRes.ok || !opRes.ok || !infraRes.ok) {
    throw fetchError("refused", "the site would not serve the bundle or the keys")
  }
  try {
    const bundleJson = await bundleRes.text()
    return { bundleJson, keys: [...keyRows(await opRes.json()), ...keyRows(await infraRes.json())] }
  } catch (e) {
    throw fetchError("refused", "the published keys could not be read")
  }
}

/**
 * The lines check what the page carries; the gate checks the published
 * bundle. Tie them together: every value a line uses must be the
 * published one, and the keys the signature lines use must be published
 * keys of the right class. Returns null when they agree, or what differs.
 */
export function pageBindingProblem(d, bundle, keys) {
  const sortedEntries = list => list.map(e => ({ uuid: e.uuid, weight: e.weight }))
    .sort((a, b) => (a.uuid < b.uuid ? -1 : a.uuid > b.uuid ? 1 : 0))
  const results = list => list.map(r => ({ entry_id: r.entry_id, position: r.position }))
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
  const published = cls => keys.some(k => k.key_class === cls && k.public_key_hex === (cls === "operator" ? d.operatorPublicKeyHex : d.infraPublicKeyHex))

  if (d.drawId !== bundle.draw_id) return "draw id"
  // Values shown in the line text, not only the ones checked.
  if (String(d.entryCount) !== String(bundle.entries.length)) return "entry count"
  if (String(d.winnerCount) !== String(bundle.results.length)) return "winner count"
  if (String(d.drandRound) !== String(JSON.parse(bundle.execution_receipt.payload_jcs).drand_round)) return "drand round"
  if (d.lockReceiptJcs !== bundle.lock_receipt.payload_jcs) return "lock receipt"
  if (d.lockSignatureHex !== bundle.lock_receipt.signature_hex) return "lock signature"
  if (d.executionReceiptJcs !== bundle.execution_receipt.payload_jcs) return "execution receipt"
  if (d.executionSignatureHex !== bundle.execution_receipt.signature_hex) return "execution signature"
  if (!same(sortedEntries(JSON.parse(d.entriesJson)), sortedEntries(bundle.entries))) return "entries"
  if (!same(results(JSON.parse(d.resultsJson)), results(bundle.results))) return "results"
  if (!published("operator")) return "operator key"
  if (!published("infrastructure")) return "infrastructure key"
  return null
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
 *
 * Only lock schema 6 / execution schema 5 receipts are checked. Anything
 * else (no receipt, an older schema, an unknown tag) throws, so the seed
 * line fails.
 */
export function seedPlan(wasm, exec, execJcs, lock) {
  if (!exec) throw new Error("no signed execution receipt")
  if (exec.schema_version !== V6_EXEC_SCHEMA) {
    throw new Error(`execution receipt schema ${exec.schema_version} isn't one this page checks`)
  }
  if (lock && lock.schema_version !== V6_LOCK_SCHEMA) {
    throw new Error(`lock receipt schema ${lock.schema_version} isn't one this page checks`)
  }

  const tag = exec.entropy_composition
  const signed = (formula, value, fallbackLabel = null) =>
    ({ formula, value, randomness: exec.drand_randomness, fallbackLabel })

  if (tag === LANDOBS_TAG) {
    const state = wasm.landobs_exec_state_wasm(execJcs)
    if (state === "weather") return signed("weather", exec.weather_value)
    if (state === "frequency") return signed("frequency", exec.freq_value, LANDOBS_FREQUENCY_LABEL)
    if (state === "drand_only") return signed("drand_only", null, LANDOBS_DRAND_ONLY_LABEL)
    throw new Error(`unknown observation state: ${state}`)
  }

  if (tag === FREQ_TAG) {
    // Two states: readings with no reason, or no readings with the tag's
    // reason; every weather field null. Anything else is refused.
    if (FREQ_WEATHER_KEYS.some(k => !(k in exec) || exec[k] !== null)) {
      throw new Error("a grid-frequency receipt carries a weather field")
    }
    if (typeof exec.freq_value === "string" && exec.freq_fallback_reason === null) {
      return signed("frequency", exec.freq_value)
    }
    if (exec.freq_value === null && exec.freq_fallback_reason === FREQ_FALLBACK_REASON) {
      return signed("drand_only", null, FREQ_DRAND_ONLY_LABEL)
    }
    throw new Error("grid-frequency receipt is in neither state (readings, or drand only after no_frequency_by_deadline)")
  }

  throw new Error(`unknown entropy tag: ${tag}`)
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
  // Any receipt data at all means the published proof decides; only a
  // page with none is checked on its own (amber at best).
  const gated = receiptState(d) !== "none"
  const result = {
    hasReceipts: receipts, receiptState: receiptState(d), gate: null, bindingProblem: null,
    lines: [], verdict: null, fatal: null,
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
  let lockSigned = null
  if (gated) {
    if (!published) return refuse(REFUSED_RED)
    let bundle
    try {
      bundle = JSON.parse(published.bundleJson)
      execJcs = bundle.execution_receipt.payload_jcs
      exec = JSON.parse(execJcs)
      lockSigned = JSON.parse(bundle.lock_receipt.payload_jcs)
      result.bindingProblem = pageBindingProblem(d, bundle, published.keys)
    } catch (_e) {
      return refuse(REFUSED_RED)
    }
    // A page that differs from what was published is refused like a bad bundle.
    result.gate = result.bindingProblem === null && runGate(wasm, published.bundleJson, published.keys)
  }

  const lines = result.lines
  const statusFor = ok => {
    if (!ok) return "fail"
    if (!gated) return "unsigned"
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
    result.verdict = finalVerdict({ gate: result.gate, linesPassed: lines.every(l => l.ok), hasReceipts: gated })
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
    plan = seedPlan(wasm, exec, execJcs, lockSigned)
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
    // The readings' year: the signed window start T's.
    const t = lockSigned && typeof lockSigned.freq_start === "string" ? lockSigned.freq_start : ""
    result.bmrsYear = t.substring(0, 4) || String(new Date().getUTCFullYear())
  }

  // the draw itself (shown as a count; the next line checks it)
  settle({ id: "draw", kind: "count", count: d.entryCount, mono: `${d.winnerCount} winners`,
           text: `winners = fair_pick.draw(${d.entryCount} entries, seed, ${d.winnerCount}) → `,
           waitLabel: "selected", passLabel: "selected", typeSpeed: 20 }, true)

  if (!check({ id: "winners", text: "assert winners == stored_results → ", passLabel: "match" },
             "MISMATCH — draw math verification failed", "Verification error", () =>
    verifyWinners(wasm, plan, d, entries, JSON.parse(d.resultsJson), parseInt(d.winnerCount)))) return done()

  const gateLine = () => settle(
    { id: "gate", text: "verify published proof bundle (attestable) → ", waitLabel: "passed", passLabel: "passed" },
    result.gate === true,
    GENERIC_RED)

  // A partial page has nothing to show for the receipt lines; the gate
  // (refused by the binding check) gives the verdict.
  if (!receipts) {
    if (gated) gateLine()
    return done()
  }

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
  // A line, never a gate: "published after the signed lock time" is the
  // gate's check, against the operator-signed locked_at.
  if (!check({ id: "drand", text: "drand beacon → ", waitLabel: "genuine, published after the signed lock time",
               passLabel: "genuine, published after the signed lock time" },
             "FAILED — the drand beacon did not verify", "drand check error", () =>
    wasm.verify_drand_wasm(exec.drand_chain, BigInt(exec.drand_round), exec.drand_signature, exec.drand_randomness)
  )) return done()

  // Observation weather: the signed hour is the one the round implies.
  // Informational; the gate checks it for real.
  if (exec.entropy_composition === LANDOBS_TAG) {
    const hourLine = { id: "observation_hour", text: "observation hour follows from the drand round → " }
    if (!check(hourLine, "MISMATCH — the signed observation hour doesn't follow from the drand round",
               "Observation hour error", () => {
      const signedHour = JSON.parse(d.lockReceiptJcs).weather_time
      hourLine.passLabel = hourLine.waitLabel = `${signedHour.substring(11, 16)} UTC`
      return signedHour === observationHour(exec.drand_round)
    })) return done()
  }

  gateLine()
  return done()
}
