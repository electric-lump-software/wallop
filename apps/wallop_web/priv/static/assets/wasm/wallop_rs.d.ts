/* tslint:disable */
/* eslint-disable */

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
 * WASM entry point for full verification pipeline.
 */
export function verify_wasm(entries_js: any, drand_randomness: string, weather_value: string | null | undefined, count: number, expected_results_js: any): boolean;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly compute_seed_drand_only_wasm: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly compute_seed_wasm: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number];
    readonly draw_wasm: (a: any, b: number, c: number, d: number) => [number, number, number];
    readonly entry_hash_wasm: (a: any) => [number, number, number];
    readonly verify_wasm: (a: any, b: number, c: number, d: number, e: number, f: number, g: any) => [number, number, number];
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
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
