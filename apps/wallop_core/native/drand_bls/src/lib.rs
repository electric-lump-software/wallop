//! drand quicknet BLS signature check, as a NIF for wallop_core.
//!
//! One function, `verify_g1(pubkey, round, sig)`: true only when `sig` is a
//! valid `bls-unchained-g1-rfc9380` signature of `round` under `pubkey` (a
//! 96-byte compressed G2 point). Any malformed input (wrong length, not a
//! point, not in the subgroup) is false. It never panics into the VM.
//!
//! The pairing check takes about a millisecond, so it runs on a dirty CPU
//! scheduler.

use drand_verify::{G2PubkeyRfc, Pubkey};
use rustler::Binary;
use std::panic::{catch_unwind, AssertUnwindSafe};

#[rustler::nif(schedule = "DirtyCpu")]
fn verify_g1(pubkey: Binary, round: u64, sig: Binary) -> bool {
    let pubkey = pubkey.as_slice();
    let sig = sig.as_slice();

    catch_unwind(AssertUnwindSafe(|| verify(pubkey, round, sig))).unwrap_or(false)
}

fn verify(pubkey: &[u8], round: u64, sig: &[u8]) -> bool {
    let Ok(pubkey) = <[u8; 96]>::try_from(pubkey) else {
        return false;
    };

    if sig.len() != 48 {
        return false;
    }

    let Ok(pk) = G2PubkeyRfc::from_fixed(pubkey) else {
        return false;
    };

    pk.verify(round, b"", sig).unwrap_or(false)
}

rustler::init!("Elixir.WallopCore.Drand.Bls.Native");

#[cfg(test)]
mod tests {
    use super::verify;

    const QUICKNET_PK: &str = "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a";
    const SIG_1000: &str = "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn accepts_a_real_round() {
        assert!(verify(&unhex(QUICKNET_PK), 1000, &unhex(SIG_1000)));
    }

    #[test]
    fn refuses_another_round() {
        assert!(!verify(&unhex(QUICKNET_PK), 1001, &unhex(SIG_1000)));
    }

    #[test]
    fn refuses_malformed_input_without_panicking() {
        let pk = unhex(QUICKNET_PK);
        assert!(!verify(&pk, 1000, &[]));
        assert!(!verify(&pk, 1000, &[0u8; 47]));
        assert!(!verify(&pk, 1000, &[0u8; 96]));
        assert!(!verify(&pk, 1000, &[0xffu8; 48]));
        assert!(!verify(&pk[..95], 1000, &unhex(SIG_1000)));
        assert!(!verify(&[0u8; 96], 1000, &unhex(SIG_1000)));
    }
}
