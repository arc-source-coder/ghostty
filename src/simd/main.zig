//! SIMD-optimized routines. If `build_options.simd` is false, then the API
//! still works but we fall back to pure Zig scalar implementations.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;

const codepoint_width = @import("codepoint_width.zig");
pub const base64 = @import("base64.zig");
pub const index_of = @import("index_of.zig");
pub const vt = @import("vt.zig");
pub const codepointWidth = codepoint_width.codepointWidth;

/// The number of vector lanes to use for manually vectorized hot
/// loops operating on elements of type T, or null if the target has
/// no usable SIMD support and a plain scalar loop should be used
/// instead (e.g. wasm32 without simd128).
///
/// This is twice the native vector width so that each iteration works
/// two vector registers, giving better instruction-level parallelism.
pub fn lanes(comptime T: type) ?comptime_int {
    const native = std.simd.suggestVectorLength(T) orelse return null;
    return native * 2;
}

/// Returns the index of the first true lane of `mask`, or null if no
/// lane is true. `T` is the element type compared to produce `mask`.
///
/// This is for scan loops, which call it once per vector and almost
/// always get null. Unlike `std.simd.firstTrue`, which finds the index
/// with a select and a min-reduction, it turns the mask into a bitmask,
/// which most targets do with one movemask. Targets without a movemask,
/// like aarch64, use `firstTrueNarrowed` instead, because LLVM's
/// emulation of one takes several instructions per register.
pub inline fn firstTrue(comptime T: type, mask: anytype) ?usize {
    if (comptime builtin.cpu.arch.isAARCH64()) {
        return firstTrueNarrowed(T, mask);
    }

    const len = @typeInfo(@TypeOf(mask)).vector.len;
    const bits: @Int(.unsigned, len) = @bitCast(mask);
    if (bits == 0) return null;
    return @ctz(bits);
}

/// `firstTrue` for targets without a movemask, like aarch64.
///
/// A 128-bit register of lanes that are all ones or all zeros narrows
/// to a 64-bit integer, with half of each lane's bits, in one
/// instruction (shrn or xtn on aarch64), and the integer can then be
/// tested and searched like a movemask.
inline fn firstTrueNarrowed(comptime T: type, mask: anytype) ?usize {
    const len = @typeInfo(@TypeOf(mask)).vector.len;
    const U = @Int(.unsigned, @bitSizeOf(T));
    const V = @Vector(len, U);
    const bits_per_lane = @bitSizeOf(U) / 2;

    // Widen the mask to lanes of T's size. The compare that produced it
    // already holds it that way, so this select is free.
    const ones: V = @splat(std.math.maxInt(U));
    const zeros: V = @splat(0);
    const wide: V = @select(U, mask, ones, zeros);

    if (comptime @bitSizeOf(V) <= 128) {
        const bits = halfLanes(wide);
        if (bits == 0) return null;
        return @ctz(bits) / bits_per_lane;
    }

    // A mask in two registers (see `lanes`). Scan loops almost always
    // find no true lane, so test both registers ORed together, which
    // narrows once, and narrow each on its own only on a hit.
    comptime assert(@bitSizeOf(V) == 256);
    const lo = std.simd.extract(wide, 0, len / 2);
    const hi = std.simd.extract(wide, len / 2, len / 2);
    if (halfLanes(lo | hi) == 0) return null;

    const lo_bits = halfLanes(lo);
    if (lo_bits != 0) return @ctz(lo_bits) / bits_per_lane;
    return len / 2 + @ctz(halfLanes(hi)) / bits_per_lane;
}

/// Narrows a vector of lanes that are all ones or all zeros to an
/// integer with half of each lane's bits, lane 0 in the low bits.
inline fn halfLanes(v: anytype) @Int(.unsigned, @bitSizeOf(@TypeOf(v)) / 2) {
    const info = @typeInfo(@TypeOf(v)).vector;

    // Bytes narrow to nibbles, and there is no vector of nibbles, so
    // shift each pair of bytes right by a nibble and keep the low byte:
    // the high nibble of the first and the low nibble of the second
    // (shrn on aarch64).
    if (comptime info.child == u8) {
        const pairs: @Vector(info.len / 2, u16) = @bitCast(v);
        const narrowed: @Vector(info.len / 2, u8) = @truncate(pairs >> @splat(4));
        return @bitCast(narrowed);
    }

    // Wider lanes keep their low half (xtn on aarch64).
    const Half = @Int(.unsigned, @bitSizeOf(info.child) / 2);
    const narrowed: @Vector(info.len, Half) = @truncate(v);
    return @bitCast(narrowed);
}

test firstTrue {
    const testing = std.testing;

    // Check both implementations on every target, with a second true
    // lane after the first so an index taken from the wrong end or the
    // wrong register fails.
    inline for (.{ u8, u16, u32, u64 }) |T| {
        inline for (.{ 64, 128, 256 }) |bits| {
            const len = bits / @bitSizeOf(T);
            const none: @Vector(len, bool) = @splat(false);
            try testing.expectEqual(null, firstTrue(T, none));
            try testing.expectEqual(null, firstTrueNarrowed(T, none));

            for (0..len) |first| {
                var set: [len]bool = @splat(false);
                set[first] = true;
                set[len - 1] = true;
                const mask: @Vector(len, bool) = set;
                try testing.expectEqual(first, firstTrue(T, mask));
                try testing.expectEqual(first, firstTrueNarrowed(T, mask));
            }
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
