/* tslint:disable */
/* eslint-disable */

/**
 * WASM entry point for anchor_root.
 */
export function anchor_root_wasm(op_root_hex: string, exec_root_hex: string): string;

/**
 * WASM entry point for build_execution_receipt_payload.
 */
export function build_execution_receipt_payload_wasm(input_js: any): string;

/**
 * WASM entry point for build_receipt_payload (lock receipt v2).
 */
export function build_receipt_payload_wasm(input_js: any): string;

/**
 * WASM entry point for compute_seed (drand-only).
 */
export function compute_seed_drand_only_wasm(entry_hash: string, drand_randomness: string): any;

/**
 * WASM entry point for the grid-frequency seed.
 */
export function compute_seed_freq_wasm(entry_hash: string, drand_randomness: string, freq_value: string): any;

/**
 * WASM entry point for compute_seed.
 */
export function compute_seed_wasm(entry_hash: string, drand_randomness: string, weather_value: string): any;

/**
 * WASM entry point for draw.
 */
export function draw_wasm(entries_js: any, seed_js: Uint8Array, count: number): any;

/**
 * WASM entry point for entry_hash.
 *
 * Takes `draw_id` (the public draw UUID) and an entries array. Each
 * entry's `id` field is interpreted as the public UUID at this
 * boundary. See `protocol::entry_hash` for the canonical form.
 */
export function entry_hash_wasm(draw_id: string, entries_js: any): any;

/**
 * WASM entry point for key_id.
 */
export function key_id_wasm(public_key_hex: string): string;

/**
 * The state of an execution receipt under the observation-weather tag,
 * read from its signed payload (`payload_jcs`) by the same three-state
 * table the verifier enforces: `"weather"`, `"frequency"` or
 * `"drand_only"`. Any other combination of the five fields, or a payload
 * that is not a JSON object, is an error. A page picks its seed formula
 * from this, never from which field happens to be present.
 *
 * This selects a seed formula; it is not a check. It does not verify
 * signatures, the tag, the station or `freq_start`. Only
 * `verify_bundle_*` decides whether a bundle is valid, and a page must
 * show no seed match unless that gate passes.
 */
export function landobs_exec_state_wasm(exec_payload_jcs: string): string;

/**
 * WASM entry point for lock_receipt_hash.
 */
export function lock_receipt_hash_wasm(payload_jcs: string): string;

/**
 * WASM entry point for merkle_root.
 */
export function merkle_root_wasm(leaves_js: any): string;

/**
 * WASM entry point for receipt_schema_version.
 */
export function receipt_schema_version_wasm(payload_jcs: string): string | undefined;

/**
 * Verify a whole v5/v4 (resolver-driven) proof bundle in the browser.
 *
 * **This is the browser gate.** The proof page's green result must come
 * from this function returning `true` in attestable mode, and from
 * nothing else: not from `verify_drand_wasm`, not from the deprecated
 * `verify_full_wasm`, not from the per-line checks the page shows
 * alongside it.
 *
 * It runs the full step pipeline (`verify_bundle_with`): the same checks
 * as the CLI, including the drand BLS signature, the entropy binding and
 * temporal binding.
 *
 * Keys: the JS side fetches them out of band and passes them in as
 * `resolved_keys_js`, an array of
 * `{key_id, public_key_hex, key_class, inserted_at}`. For the attestable
 * gate (`mode = "attestable"`) they must come from wallop's
 * `/operator/:slug/keys` endpoint, never from the bundle or other page
 * data: keys taken from the bundle being verified prove only that the
 * bundle agrees with itself. `"attributable"` is for keys checked against
 * a pinned `.well-known` document.
 *
 * The `mode` argument is recorded on the report and MUST match the trust
 * root the JS side actually consulted. The verifier crate does not police
 * this association — see `verify_bundle_with`.
 *
 * Returns `true` iff the report passes (`VerificationReport::passed`).
 * A bundle that fails to parse, an unknown mode or a malformed key is an
 * `Err`. Per-step diagnostics are not surfaced from this entry point yet.
 */
export function verify_bundle_with_resolved_keys_wasm(bundle_json: string, resolved_keys_js: any, mode: string): boolean;

/**
 * WASM entry point for the drand check on its own, so the proof page can
 * show it as a separate line. True iff the chain is the pinned quicknet
 * chain, the BLS signature is valid for `round`, and
 * sha256(signature) == randomness.
 *
 * Pass every value from the signed execution receipt (`drand_chain`,
 * `drand_round`, `drand_signature`, `drand_randomness`), never from
 * unsigned page data such as the bundle's `entropy` block: a genuine
 * beacon for some other round proves nothing about this draw.
 *
 * Hex inputs must be lower case, as the receipt carries them. The chain
 * hash and randomness are compared exactly, so upper case is rejected
 * (fails closed).
 *
 * Never a gate: it does not check that the beacon belongs to this draw,
 * fed its seed, or published after the lock. The gate is
 * `verify_bundle_with_resolved_keys_wasm`.
 */
export function verify_drand_wasm(chain_hash: string, round: bigint, signature_hex: string, randomness_hex: string): boolean;

/**
 * WASM entry point for `verify_freq`: winners recomputed with the
 * grid-frequency seed.
 *
 * Choose between `verify_wasm` and `verify_freq_wasm` from the signed
 * execution receipt, never from which value happens to be present. Under
 * the grid-frequency tag, use `verify_freq_wasm`. Under the weather tag,
 * `landobs_exec_state_wasm` decides: `verify_wasm` with the value in state
 * (a) `"weather"`, `verify_freq_wasm` with the value in state (b)
 * `"frequency"`, and either with no value in state (c) `"drand_only"`.
 */
export function verify_freq_wasm(draw_id: string, entries_js: any, drand_randomness: string, freq_value: string | null | undefined, count: number, expected_results_js: any): boolean;

/**
 * WASM entry point for `verify_full`.
 *
 * **Deprecated: it checks less than the step pipeline.** It is not a
 * gate; the proof page gates on `verify_bundle_with_resolved_keys_wasm`.
 * See `verify_full` for exactly what it does and does not check.
 *
 * `winner_count` is extracted from the signed lock receipt, not passed externally.
 */
export function verify_full_wasm(lock_receipt_jcs: string, lock_signature_hex: string, operator_public_key_hex: string, execution_receipt_jcs: string, execution_signature_hex: string, infrastructure_public_key_hex: string, entries_js: any): boolean;

/**
 * WASM entry point for verify_receipt.
 */
export function verify_receipt_wasm(payload_jcs: string, signature_hex: string, public_key_hex: string): boolean;

/**
 * WASM entry point for full verification pipeline.
 */
export function verify_wasm(draw_id: string, entries_js: any, drand_randomness: string, weather_value: string | null | undefined, count: number, expected_results_js: any): boolean;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly anchor_root_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly build_execution_receipt_payload_wasm: (a: number, b: number) => void;
    readonly build_receipt_payload_wasm: (a: number, b: number) => void;
    readonly compute_seed_drand_only_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly compute_seed_freq_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly compute_seed_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly draw_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly entry_hash_wasm: (a: number, b: number, c: number, d: number) => void;
    readonly key_id_wasm: (a: number, b: number, c: number) => void;
    readonly landobs_exec_state_wasm: (a: number, b: number, c: number) => void;
    readonly lock_receipt_hash_wasm: (a: number, b: number, c: number) => void;
    readonly merkle_root_wasm: (a: number, b: number) => void;
    readonly receipt_schema_version_wasm: (a: number, b: number, c: number) => void;
    readonly verify_bundle_with_resolved_keys_wasm: (a: number, b: number, c: number, d: number, e: number, f: number) => void;
    readonly verify_drand_wasm: (a: number, b: number, c: bigint, d: number, e: number, f: number, g: number) => number;
    readonly verify_freq_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number) => void;
    readonly verify_full_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number, m: number, n: number) => void;
    readonly verify_receipt_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly verify_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number) => void;
    readonly __wbindgen_export: (a: number, b: number) => number;
    readonly __wbindgen_export2: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_export3: (a: number) => void;
    readonly __wbindgen_add_to_stack_pointer: (a: number) => number;
    readonly __wbindgen_export4: (a: number, b: number, c: number) => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
