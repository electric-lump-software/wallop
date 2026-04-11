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
 * WASM entry point for compute_seed.
 */
export function compute_seed_wasm(entry_hash: string, drand_randomness: string, weather_value: string): any;

/**
 * WASM entry point for draw.
 */
export function draw_wasm(entries_js: any, seed_js: Uint8Array, count: number): any;

/**
 * WASM entry point for entry_hash.
 */
export function entry_hash_wasm(entries_js: any): any;

/**
 * WASM entry point for key_id.
 */
export function key_id_wasm(public_key_hex: string): string;

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
 * WASM entry point for verify_full.
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
export function verify_wasm(entries_js: any, drand_randomness: string, weather_value: string | null | undefined, count: number, expected_results_js: any): boolean;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly anchor_root_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly build_execution_receipt_payload_wasm: (a: number, b: number) => void;
    readonly build_receipt_payload_wasm: (a: number, b: number) => void;
    readonly compute_seed_drand_only_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly compute_seed_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly draw_wasm: (a: number, b: number, c: number, d: number, e: number) => void;
    readonly entry_hash_wasm: (a: number, b: number) => void;
    readonly key_id_wasm: (a: number, b: number, c: number) => void;
    readonly lock_receipt_hash_wasm: (a: number, b: number, c: number) => void;
    readonly merkle_root_wasm: (a: number, b: number) => void;
    readonly receipt_schema_version_wasm: (a: number, b: number, c: number) => void;
    readonly verify_full_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number, m: number, n: number) => void;
    readonly verify_receipt_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => void;
    readonly verify_wasm: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number) => void;
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
