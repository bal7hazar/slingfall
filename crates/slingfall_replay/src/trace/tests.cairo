use slingfall_level::hash::to_felts;
use slingfall_testing::opaque;
use crate::main::fixtures::pile10_felts;
use crate::main::tests::{reference_inputs, reference_outputs};
use super::{main_trace, push_i64, push_u32};

fn i64_text(value: i64) -> ByteArray {
    let mut line: ByteArray = "";
    push_i64(ref line, value);
    line
}

#[test]
fn test_push_i64() {
    assert_eq!(i64_text(0), " 0");
    assert_eq!(i64_text(7), " 7");
    assert_eq!(i64_text(10), " 10");
    assert_eq!(i64_text(99), " 99");
    assert_eq!(i64_text(100), " 100");
    assert_eq!(i64_text(101), " 101");
    assert_eq!(i64_text(-1), " -1");
    assert_eq!(i64_text(4294967296), " 4294967296");
    assert_eq!(i64_text(-42133629174), " -42133629174");
    assert_eq!(i64_text(0x7fffffffffffffff), " 9223372036854775807");
    assert_eq!(i64_text(-0x8000000000000000), " -9223372036854775808");
}

#[test]
fn test_push_u32_appends() {
    let mut line: ByteArray = "frame";
    push_u32(ref line, 334);
    push_u32(ref line, 0);
    push_u32(ref line, 0xffffffff);
    assert_eq!(line, "frame 334 0 4294967295");
}

/// Step probe: the trace build on the reference shot; it returns the proof build's outputs.
#[test]
fn steps_main_trace__pile10_reference() {
    let felts = main_trace(opaque(pile10_felts()), opaque(to_felts(@reference_inputs())));
    assert_eq!(felts, reference_outputs());
}

/// Step probe: one `i64` in decimal (19 digits and a sign).
#[test]
fn steps_push_i64__min() {
    let mut line: ByteArray = "";
    push_i64(ref line, opaque(-0x8000000000000000));
    opaque(line);
}

/// Formatter candidates (`AGENTS.md` §2.5), measured by the `steps_alt_*` probes.
mod alternatives {
    const PAIRS: [felt252; 100] = [
        '00', '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12', '13', '14',
        '15', '16', '17', '18', '19', '20', '21', '22', '23', '24', '25', '26', '27', '28', '29',
        '30', '31', '32', '33', '34', '35', '36', '37', '38', '39', '40', '41', '42', '43', '44',
        '45', '46', '47', '48', '49', '50', '51', '52', '53', '54', '55', '56', '57', '58', '59',
        '60', '61', '62', '63', '64', '65', '66', '67', '68', '69', '70', '71', '72', '73', '74',
        '75', '76', '77', '78', '79', '80', '81', '82', '83', '84', '85', '86', '87', '88', '89',
        '90', '91', '92', '93', '94', '95', '96', '97', '98', '99',
    ];

    /// Candidate: one `DivRem` by 100 per two digits, the pair's two ASCII bytes from a table.
    pub fn push_decimal_pairs(ref line: ByteArray, magnitude: u64, negative: bool) {
        let pairs = PAIRS.span();
        let mut word: felt252 = 0;
        let mut scale: felt252 = 1;
        let mut len: usize = 0;
        let mut rest = magnitude;
        let hundred: NonZero<u64> = 100;
        while rest >= 100 {
            let (q, pair) = DivRem::div_rem(rest, hundred);
            let pair: u32 = pair.try_into().unwrap();
            word += *pairs[pair] * scale;
            scale *= 0x10000;
            len += 2;
            rest = q;
        }
        if rest >= 10 {
            let pair: u32 = rest.try_into().unwrap();
            word += *pairs[pair] * scale;
            scale *= 0x10000;
            len += 2;
        } else {
            word += (rest.into() + '0') * scale;
            scale *= 0x100;
            len += 1;
        }
        if negative {
            word += '-' * scale;
            scale *= 0x100;
            len += 1;
        }
        word += ' ' * scale;
        line.append_word(word, len + 1);
    }

    pub fn push_i64_pairs(ref line: ByteArray, value: i64) {
        if value < 0 {
            push_decimal_pairs(ref line, (-value).try_into().unwrap(), true);
        } else {
            push_decimal_pairs(ref line, value.try_into().unwrap(), false);
        }
    }
}

/// Typical pose values of a pile10 frame: `x`, `y`, `re`, `im` of one body, 11 times.
fn typical() -> Array<i64> {
    let mut values: Array<i64> = array![];
    for _ in 0..11_u32 {
        values.append_span([90208970903, 2146577797, 4294967255, -598782].span());
    }
    values
}

/// Step probe: 44 typical values with the kept formatter (`push_i64`).
#[test]
fn steps_push_i64__frame_values() {
    let values = opaque(typical());
    let mut line: ByteArray = "";
    for value in values {
        push_i64(ref line, value);
    }
    opaque(line);
}

/// Step probe: the same values with the pair-table candidate.
#[test]
fn steps_alt_push_decimal_pairs__frame_values() {
    let values = opaque(typical());
    let mut line: ByteArray = "";
    for value in values {
        alternatives::push_i64_pairs(ref line, value);
    }
    opaque(line);
}

#[test]
fn test_alternatives_agree() {
    let mut a: ByteArray = "";
    let mut b: ByteArray = "";
    for value in typical() {
        push_i64(ref a, value);
        alternatives::push_i64_pairs(ref b, value);
    }
    assert_eq!(a, b);
}
