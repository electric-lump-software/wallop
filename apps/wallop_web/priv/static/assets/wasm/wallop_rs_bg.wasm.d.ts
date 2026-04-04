/* tslint:disable */
/* eslint-disable */
export const memory: WebAssembly.Memory;
export const compute_seed_drand_only_wasm: (a: number, b: number, c: number, d: number) => [number, number, number];
export const compute_seed_wasm: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number];
export const draw_wasm: (a: any, b: number, c: number, d: number) => [number, number, number];
export const entry_hash_wasm: (a: any) => [number, number, number];
export const verify_wasm: (a: any, b: number, c: number, d: number, e: number, f: number, g: any) => [number, number, number];
export const __wbindgen_malloc: (a: number, b: number) => number;
export const __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
export const __wbindgen_exn_store: (a: number) => void;
export const __externref_table_alloc: () => number;
export const __wbindgen_externrefs: WebAssembly.Table;
export const __externref_table_dealloc: (a: number) => void;
export const __wbindgen_start: () => void;
