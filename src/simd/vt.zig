const std = @import("std");
const options = @import("build_options");
const assert = @import("../quirks.zig").inlineAssert;
const firstTrue = @import("main.zig").firstTrue;

// vt.cpp
extern "c" fn ghostty_simd_decode_utf8_until_control_seq(
    input: [*]const u8,
    count: usize,
    output: [*]u32,
    output_count: *usize,
) usize;

const DecodeResult = struct {
    consumed: usize,
    decoded: usize,
};

/// Decode UTF-8 from input into output until an ESC.
pub fn utf8DecodeUntilControlSeq(
    input: []const u8,
    output: []u32,
) DecodeResult {
    assert(output.len >= input.len);

    if (comptime !options.simd) return utf8DecodeUntilControlSeqScalar(input, output);

    // Runs between escape sequences are often a few bytes, like a single
    // glyph between two SGR sequences. vt.cpp would pay a Highway
    // dispatch to find their ESC, and simdutf its own dispatch and a
    // virtual call, only to decode them with scalar code anyway: simdutf
    // decodes a 64-byte block with SIMD only while a margin covering the
    // last few characters follows it, 16 bytes for two-byte text. So
    // decode runs that end within that many bytes here.
    //
    // One compare of all those bytes finds whether the ESC is among
    // them. It doesn't stop early at an ESC in the first few bytes like
    // std.mem.indexOfScalar, but it doesn't loop or finish a byte at a
    // time either, which costs long runs more.
    const short_len = 80;
    if (input.len <= short_len) return utf8DecodeUntilControlSeqScalar(input, output);
    const V = @Vector(short_len, u8);
    const short: V = input[0..short_len].*;
    if (@reduce(.Or, short == @as(V, @splat(0x1B)))) {
        return utf8DecodeUntilControlSeqScalar(input, output);
    }

    return utf8DecodeUntilControlSeqSimd(input, output);
}

fn utf8DecodeUntilControlSeqSimd(
    input: []const u8,
    output: []u32,
) DecodeResult {
    var decoded: usize = 0;
    const consumed = ghostty_simd_decode_utf8_until_control_seq(
        input.ptr,
        input.len,
        output.ptr,
        &decoded,
    );
    return .{ .consumed = consumed, .decoded = decoded };
}

fn utf8DecodeUntilControlSeqScalar(
    input: []const u8,
    output: []u32,
) DecodeResult {
    // Decode one codepoint at a time until an ESC, following the
    // W3C/Unicode "U+FFFD Substitution of Maximal Subparts" algorithm
    // for ill-formed subsequences.
    var i: usize = 0;
    var count: usize = 0;
    while (i < input.len) {
        const b0 = input[i];
        if (b0 < 0x80) {
            if (b0 == 0x1B) break;

            // Widen ASCII a whole vector at a time, up to the next ESC
            // or non-ASCII byte. The output past that gets overwritten,
            // and there is room for it: count <= i and output.len >=
            // input.len. Zig doesn't vectorize loops, so this has to be
            // explicit. It also works when simd=false, which only
            // disables our C++ SIMD code, on targets like wasm32+simd128.
            if (comptime std.simd.suggestVectorLength(u8)) |vl| if (i + vl <= input.len) {
                const V = @Vector(vl, u8);
                while (true) {
                    const v: V = input[i..][0..vl].*;
                    output[count..][0..vl].* = @as(@Vector(vl, u32), v);
                    const stop = (v >= @as(V, @splat(0x80))) | (v == @as(V, @splat(0x1B)));
                    if (firstTrue(u8, stop)) |n| {
                        count += n;
                        i += n;
                        break;
                    }
                    count += vl;
                    i += vl;
                    if (i + vl > input.len) break;
                }
                continue;
            };

            output[count] = b0;
            count += 1;
            i += 1;
            continue;
        }

        // Fast path for a complete, well-formed sequence: assemble the
        // codepoint from the payload bits of each byte, then check that
        // every continuation byte is 80-BF and that the codepoint is
        // neither overlong, a surrogate, nor above U+10FFFF, which
        // together are equivalent to the byte ranges of Unicode
        // Table 3-7.
        const rest = input[i..];
        if (b0 >= 0xC2 and b0 < 0xE0 and rest.len >= 2) {
            const c1 = rest[1] ^ 0x80;
            if (c1 < 0x40) {
                output[count] = @as(u32, b0 & 0x1F) << 6 | c1;
                count += 1;
                i += 2;
                continue;
            }
        } else if (b0 >= 0xE0 and b0 < 0xF0 and rest.len >= 3) {
            const c1 = rest[1] ^ 0x80;
            const c2 = rest[2] ^ 0x80;
            const cp = @as(u32, b0 & 0x0F) << 12 | @as(u32, c1) << 6 | c2;
            if (c1 | c2 < 0x40 and cp >= 0x800 and cp & 0xF800 != 0xD800) {
                output[count] = cp;
                count += 1;
                i += 3;
                continue;
            }
        } else if (b0 >= 0xF0 and b0 < 0xF5 and rest.len >= 4) {
            const c1 = rest[1] ^ 0x80;
            const c2 = rest[2] ^ 0x80;
            const c3 = rest[3] ^ 0x80;
            const cp = @as(u32, b0 & 0x07) << 18 | @as(u32, c1) << 12 |
                @as(u32, c2) << 6 | c3;
            if (c1 | c2 | c3 < 0x40 and cp >= 0x10000 and cp <= 0x10FFFF) {
                output[count] = cp;
                count += 1;
                i += 4;
                continue;
            }
        }

        // Otherwise the sequence is ill-formed or cut off by the end of
        // the input. A continuation byte (80-BF) or an invalid byte
        // (C0-C1, F5-FF) as lead is its own maximal subpart: one FFFD.
        if (b0 < 0xC2 or b0 > 0xF4) {
            output[count] = 0xFFFD;
            count += 1;
            i += 1;
            continue;
        }

        // Count the continuation bytes that form a valid prefix (the
        // maximal subpart). Only the first has a lead-dependent range
        // per Table 3-7; later ones are always 80-BF. An ESC is never in
        // range, so a sequence cut off by an ESC can never be completed
        // and its maximal subpart maps to a single FFFD.
        const seq_len: usize = if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else 4;
        const cb1_lo: u8, const cb1_hi: u8 = switch (b0) {
            0xE0 => .{ 0xA0, 0xBF },
            0xED => .{ 0x80, 0x9F },
            0xF0 => .{ 0x90, 0xBF },
            0xF4 => .{ 0x80, 0x8F },
            else => .{ 0x80, 0xBF },
        };
        var valid: usize = 1;
        while (valid < seq_len) : (valid += 1) {
            // A sequence cut off by the end of the input may be completed
            // by future input, so stop without consuming it.
            if (valid == rest.len) return .{
                .consumed = i,
                .decoded = count,
            };
            const lo: u8 = if (valid == 1) cb1_lo else 0x80;
            const hi: u8 = if (valid == 1) cb1_hi else 0xBF;
            if (rest[valid] < lo or rest[valid] > hi) break;
        }
        output[count] = 0xFFFD;
        count += 1;
        i += valid;
    }

    return .{
        .consumed = i,
        .decoded = count,
    };
}

// Differential test: the SIMD implementation must agree with the
// scalar implementation on any input. Exercises random mixtures of
// ASCII, escapes, controls, valid and invalid UTF-8, at various
// lengths (including chunk-boundary straddling cases).
test "decode simd matches scalar" {
    if (comptime !options.simd) return error.SkipZigTest;

    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xf00dface);
    const rand = prng.random();

    const edges = [_]u8{
        0x1B, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF,
        0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF,
    };
    var input: [257]u8 = undefined;
    var out_simd: [input.len]u32 = undefined;
    var out_scalar: [input.len]u32 = undefined;

    for (0..10_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, input.len);
        const style = rand.intRangeAtMost(u8, 0, 3);
        for (input[0..len]) |*b| {
            b.* = switch (style) {
                // Mostly ASCII with occasional specials.
                0 => switch (rand.intRangeAtMost(u8, 0, 20)) {
                    0 => 0x1B,
                    1 => rand.intRangeAtMost(u8, 0, 0x1F),
                    2 => rand.int(u8),
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                // Heavy multi-byte/invalid UTF-8.
                1 => switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => rand.intRangeAtMost(u8, 0x80, 0xBF),
                    1 => rand.intRangeAtMost(u8, 0xC0, 0xFF),
                    2 => 0x1B,
                    else => rand.intRangeAtMost(u8, 0x20, 0x7E),
                },
                // Bytes at the edges of the ranges of Unicode Table 3-7,
                // for overlong, surrogate and out of range sequences.
                2 => edges[rand.uintLessThan(usize, edges.len)],
                // Fully random bytes.
                else => rand.int(u8),
            };
        }

        errdefer std.debug.print("input={x}\n", .{input[0..len]});
        const res_scalar = utf8DecodeUntilControlSeqScalar(input[0..len], &out_scalar);

        // Both vt.cpp alone, which decodes only long runs otherwise, and
        // the decoder that picks one of the two by the length of the run.
        for ([_]*const fn ([]const u8, []u32) DecodeResult{
            utf8DecodeUntilControlSeqSimd,
            utf8DecodeUntilControlSeq,
        }) |decode| {
            const res_simd = decode(input[0..len], &out_simd);
            try testing.expectEqual(res_scalar.consumed, res_simd.consumed);
            try testing.expectEqual(res_scalar.decoded, res_simd.decoded);
            try testing.expectEqualSlices(
                u32,
                out_scalar[0..res_scalar.decoded],
                out_simd[0..res_simd.decoded],
            );
        }
    }
}

test "decode no escape" {
    const testing = std.testing;

    var output: [1024]u32 = undefined;

    // TODO: many more test cases
    {
        const str: [128 * 5]u8 = comptime std.simd.repeat(128 * 5, "hello".*);
        try testing.expectEqual(DecodeResult{
            .consumed = str.len,
            .decoded = str.len,
        }, utf8DecodeUntilControlSeq(&str, &output));
    }
}

test "decode ASCII to escape" {
    const testing = std.testing;

    var output: [1024]u32 = undefined;

    // TODO: many more test cases
    {
        const prefix: [64 * 5]u8 = comptime std.simd.repeat(64 * 5, "hello".*);
        const payload: [64 * 5]u8 = comptime std.simd.repeat(64 * 5, "world".*);
        const str = prefix ++ "\x1b" ++ payload;
        try testing.expectEqual(DecodeResult{
            .consumed = prefix.len,
            .decoded = prefix.len,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}

test "decode ASCII ends at ESC and non-ASCII" {
    const testing = std.testing;

    var input: [130]u8 = undefined;
    var output: [input.len]u32 = undefined;

    // An ESC or a non-ASCII byte at offsets on both sides of the 16-,
    // 32- and 64-byte chunk boundaries and in the scalar tail, after
    // ASCII with every C0 control in it.
    const offsets = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128 };
    for (offsets) |offset| {
        for (&input, 0..) |*b, i| b.* = @intCast(i % 0x80);
        for (input[0..offset]) |*b| if (b.* == 0x1B) {
            b.* = 'x';
        };

        input[offset] = 0x1B;
        try testing.expectEqual(DecodeResult{
            .consumed = offset,
            .decoded = offset,
        }, utf8DecodeUntilControlSeq(&input, &output));

        // A lone continuation byte decodes to U+FFFD, and the ASCII
        // before it is widened.
        input[offset] = 0x80;
        const end = if (std.mem.indexOfScalarPos(u8, &input, offset, 0x1B)) |e| e else input.len;
        const res = utf8DecodeUntilControlSeq(&input, &output);
        try testing.expectEqual(DecodeResult{
            .consumed = end,
            .decoded = end,
        }, res);
        for (input[0..end], output[0..end], 0..) |b, cp, i| {
            try testing.expectEqual(if (i == offset) 0xFFFD else @as(u32, b), cp);
        }
    }
}

test "decode immediate esc sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;
    const str = "\x1b[?5s";
    try testing.expectEqual(DecodeResult{
        .consumed = 0,
        .decoded = 0,
    }, utf8DecodeUntilControlSeq(str, &output));
}

test "decode incomplete UTF-8" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // 2-byte truncated at end of buffer
    {
        const str = "hello\xc2";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // 3-byte: \xe0 expects A0-BF next, but \x00 is not in range.
    // \xe0 is a maximal subpart of length 1 → FFFD, then \x00 is ASCII NUL.
    {
        const str = "hello\xe0\x00";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 7), result.consumed);
        try testing.expectEqual(@as(usize, 7), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, 0x00), output[6]);
    }

    // 4-byte truncated at end of buffer (F0 90 is valid so far)
    {
        const str = "hello\xf0\x90";
        try testing.expectEqual(DecodeResult{
            .consumed = 5,
            .decoded = 5,
        }, utf8DecodeUntilControlSeq(str, &output));
    }
}

test "decode invalid UTF-8" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Invalid leading 2-byte sequence
    {
        const str = "hello\xc2\x01";
        try testing.expectEqual(DecodeResult{
            .consumed = 7,
            .decoded = 7,
        }, utf8DecodeUntilControlSeq(str, &output));
    }

    // Replacement will only replace the invalid leading byte.
    try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    try testing.expectEqual(@as(u32, 0x01), output[6]);
}

// Per the maximal subpart spec, bytes F5-FF are each replaced with FFFD.
test "decode invalid leading byte is replaced" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    {
        const str = "hello\xFF";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 6), result.consumed);
        try testing.expectEqual(@as(usize, 6), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
    }
}

test "decode invalid continuation in 3-byte sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xe2 expects two continuation bytes, \x28 is not one
    {
        const str = "hello\xe2\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "hello" + replacement + "(" + "world" = 12 codepoints
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}

test "decode invalid continuation in 4-byte sequence" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xf0\x90 is a valid prefix of a 4-byte sequence, but \x28 breaks it.
    // Maximal subpart is F0 90 (length 2) → single FFFD, then '(' proceeds.
    {
        const str = "hello\xf0\x90\x28world";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "hello" + FFFD + "(" + "world" = 12 codepoints
        try testing.expectEqual(@as(usize, 12), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[5]);
        try testing.expectEqual(@as(u32, '('), output[6]);
        try testing.expectEqual(@as(u32, 'w'), output[7]);
    }
}

test "decode multiple consecutive invalid bytes" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Each lone continuation byte is its own maximal subpart → one FFFD each.
    {
        const str = "a\x80\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }

    // C0 is an invalid lead byte (< C2), each byte gets its own FFFD.
    {
        const str = "a\xc0\xc0b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}

test "decode unexpected continuation byte as lead" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // 0x80 is a continuation byte appearing as a lead byte
    {
        const str = "a\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + replacement + "b" = 3 codepoints
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 'b'), output[2]);
    }
}

test "decode overlong 2-byte encoding" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xc0\xaf: C0 is invalid lead (< C2) → FFFD, AF is lone continuation → FFFD
    // Per Table 3-8: C0 AF → FFFD FFFD
    {
        const str = "a\xc0\xafb";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + "b" = 4 codepoints
        try testing.expectEqual(@as(usize, 4), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 'b'), output[3]);
    }
}

test "decode surrogate half" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xed\xa0\x80 encodes U+D800 (a surrogate). Per Table 3-7, after ED
    // the next byte must be 80-9F. A0 is out of range, so ED is a maximal
    // subpart of length 1 → FFFD. Then A0 and 80 are lone continuations
    // → FFFD each. Per Table 3-9: ED A0 80 → FFFD FFFD FFFD
    {
        const str = "a\xed\xa0\x80b";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // "a" + FFFD + FFFD + FFFD + "b" = 5 codepoints
        try testing.expectEqual(@as(usize, 5), result.decoded);
        try testing.expectEqual(@as(u32, 'a'), output[0]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[3]);
        try testing.expectEqual(@as(u32, 'b'), output[4]);
    }
}

test "decode valid multibyte surrounded by invalid" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // \xc3\xa9 = é (U+00E9), surrounded by invalid continuation bytes
    {
        const str = "\x80\xc3\xa9\x80";
        const result = utf8DecodeUntilControlSeq(str, &output);
        // replacement + é + replacement = 3 codepoints
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
        try testing.expectEqual(@as(u32, 0x00E9), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}

test "decode partial UTF-8 before escape" {
    const testing = std.testing;

    // A valid-so-far but incomplete sequence cut off by an ESC can
    // never be completed, so it is consumed and replaced by a single
    // U+FFFD (maximal subpart) rather than left pending. Only
    // sequences cut off by the true end of input are left pending.
    var output: [64]u32 = undefined;

    // 2-byte lead cut off by ESC.
    {
        const str = "hi\xc2\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }

    // 3-byte lead plus one valid continuation cut off by ESC:
    // the whole prefix is one maximal subpart, one U+FFFD.
    {
        const str = "\xe0\xa0\x1bX";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 2), result.consumed);
        try testing.expectEqual(@as(usize, 1), result.decoded);
        try testing.expectEqual(@as(u32, 0xFFFD), output[0]);
    }
}

test "decode invalid byte before escape" {
    const testing = std.testing;

    var output: [64]u32 = undefined;

    // Invalid byte followed by ESC - should replace then stop
    {
        const str = "hi\x80\x1b[0m";
        const result = utf8DecodeUntilControlSeq(str, &output);
        try testing.expectEqual(@as(usize, 3), result.consumed);
        try testing.expectEqual(@as(usize, 3), result.decoded);
        try testing.expectEqual(@as(u32, 'h'), output[0]);
        try testing.expectEqual(@as(u32, 'i'), output[1]);
        try testing.expectEqual(@as(u32, 0xFFFD), output[2]);
    }
}

// Unicode Table 3-8: U+FFFD for Non-Shortest Form Sequences
// Bytes:  C0  AF  E0  80  BF  F0  81  82  41
// Output: FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD 0041
test "Table 3-8: non-shortest form sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xC0\xAF\xE0\x80\xBF\xF0\x81\x82\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}

// Unicode Table 3-9: U+FFFD for Ill-Formed Sequences for Surrogates
// Bytes:  ED  A0  80  ED  BF  BF  ED  AF  41
// Output: FFFD FFFD FFFD FFFD FFFD FFFD FFFD FFFD 0041
test "Table 3-9: surrogate sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xED\xA0\x80\xED\xBF\xBF\xED\xAF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, 0xFFFD), output[i]);
    }
    try testing.expectEqual(@as(u32, 0x41), output[8]);
}

// Unicode Table 3-10: U+FFFD for Other Ill-Formed Sequences
// Bytes:  F4  91  92  93  FF  41  80  BF  42
// Output: FFFD FFFD FFFD FFFD FFFD 0041 FFFD FFFD 0042
test "Table 3-10: other ill-formed sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xF4\x91\x92\x93\xFF\x41\x80\xBF\x42";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]); // F4
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]); // 91
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]); // 92
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]); // 93
    try testing.expectEqual(@as(u32, 0xFFFD), output[4]); // FF
    try testing.expectEqual(@as(u32, 0x0041), output[5]); // 41
    try testing.expectEqual(@as(u32, 0xFFFD), output[6]); // 80
    try testing.expectEqual(@as(u32, 0xFFFD), output[7]); // BF
    try testing.expectEqual(@as(u32, 0x0042), output[8]); // 42
}

// Unicode Table 3-11: U+FFFD for Truncated Sequences
// Bytes:  E1  80  E2  F0  91  92  F1  BF  41
// Output: FFFD     FFFD    FFFD         FFFD     0041
test "Table 3-11: truncated sequences" {
    const testing = std.testing;
    var output: [64]u32 = undefined;

    const str = "\xE1\x80\xE2\xF0\x91\x92\xF1\xBF\x41";
    const result = utf8DecodeUntilControlSeq(str, &output);
    try testing.expectEqual(@as(usize, 9), result.consumed);
    try testing.expectEqual(@as(usize, 5), result.decoded);
    try testing.expectEqual(@as(u32, 0xFFFD), output[0]); // E1 80 (truncated 3-byte)
    try testing.expectEqual(@as(u32, 0xFFFD), output[1]); // E2 (truncated 3-byte, next byte F0 not continuation)
    try testing.expectEqual(@as(u32, 0xFFFD), output[2]); // F0 91 92 (truncated 4-byte)
    try testing.expectEqual(@as(u32, 0xFFFD), output[3]); // F1 BF (truncated 4-byte, next byte 41 not continuation)
    try testing.expectEqual(@as(u32, 0x0041), output[4]); // 41
}
