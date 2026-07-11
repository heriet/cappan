const std = @import("std");

// ── Static dictionary binary ──────────────────────────────────────────────────

const dict_data: []const u8 = @embedFile("../brotli_dictionary.bin");

// ── Word length tables (RFC 7932 §10) ────────────────────────────────────────

/// Number of dictionary bits for each word length (lengths 4-24).
pub const kNDBits = [21]u5{ 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };

/// Byte offset into the dictionary for each word length (lengths 4-24).
const kDOffset = [21]u32{
    0,      4096,   9216,   21504,  35840,  44032,  53248,
    63488,  74752,  87040,  93696,  100864, 104704, 106752,
    108928, 113536, 115968, 118528, 119872, 121280, 122016,
};

/// Number of words for each word length.
pub fn nWords(word_length: u8) u32 {
    const idx = word_length - 4;
    return @as(u32, 1) << kNDBits[idx];
}

/// Return the dictionary slice for (word_length, word_index).
pub fn getWord(word_length: u8, word_index: u32) []const u8 {
    std.debug.assert(word_length >= 4 and word_length <= 24);
    const idx = word_length - 4;
    const offset = kDOffset[idx] + word_index * word_length;
    return dict_data[offset .. offset + word_length];
}

// ── Transform definitions (RFC 7932 §8) ──────────────────────────────────────

pub const TransformType = enum {
    identity,
    ferment_first,
    ferment_all,
    omit_first_1,
    omit_first_2,
    omit_first_3,
    omit_first_4,
    omit_first_5,
    omit_first_6,
    omit_first_7,
    omit_first_8,
    omit_first_9,
    omit_last_1,
    omit_last_2,
    omit_last_3,
    omit_last_4,
    omit_last_5,
    omit_last_6,
    omit_last_7,
    omit_last_8,
    omit_last_9,
};

pub const Transform = struct {
    prefix: []const u8,
    transform_type: TransformType,
    suffix: []const u8,
};

pub const NUM_TRANSFORMS: usize = 121;

// Prefix/suffix strings (built from kPrefixSuffix / kPrefixSuffixMap).
// Index 49 is the empty string "".
const PS = struct {
    const s00 = " ";
    const s01 = ", ";
    const s02 = " of the ";
    const s03 = " of ";
    const s04 = "s ";
    const s05 = ".";
    const s06 = " and ";
    const s07 = " in ";
    const s08 = "\"";
    const s09 = " to ";
    const s10 = "\">";
    const s11 = "\n";
    const s12 = ". ";
    const s13 = "]";
    const s14 = " for ";
    const s15 = " a ";
    const s16 = " that ";
    const s17 = "'";
    const s18 = " with ";
    const s19 = " from ";
    const s20 = " by ";
    const s21 = "(";
    const s22 = ". The ";
    const s23 = " on ";
    const s24 = " as ";
    const s25 = " is ";
    const s26 = "ing ";
    const s27 = "\n\t";
    const s28 = ":";
    const s29 = "ed ";
    const s30 = "=\"";
    const s31 = " at ";
    const s32 = "ly ";
    const s33 = ",";
    const s34 = "='";
    const s35 = ".com/";
    const s36 = ". This ";
    const s37 = " not ";
    const s38 = "er ";
    const s39 = "al ";
    const s40 = "ful ";
    const s41 = "ive ";
    const s42 = "less ";
    const s43 = "est ";
    const s44 = "ize ";
    const s45 = "\xC2\xA0"; // UTF-8 non-breaking space (U+00A0)
    const s46 = "ous ";
    const s47 = " the ";
    const s48 = "e ";
    const s49 = ""; // empty (index 49 in kPrefixSuffixMap)
};

/// The 121 transforms from RFC 7932 / google/brotli transform.c
pub const transforms: [NUM_TRANSFORMS]Transform = .{
    // [ 0] prefix=49 (""),  IDENTITY,       suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s49 },
    // [ 1] prefix=49 (""),  IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s00 },
    // [ 2] prefix= 0 (" "), IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s00 },
    // [ 3] prefix=49 (""),  OMIT_FIRST_1,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_1, .suffix = PS.s49 },
    // [ 4] prefix=49 (""),  UPPERCASE_FIRST,suffix= 0 (" ")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s00 },
    // [ 5] prefix=49 (""),  IDENTITY,       suffix=47 (" the ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s47 },
    // [ 6] prefix= 0 (" "), IDENTITY,       suffix=49 ("")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s49 },
    // [ 7] prefix= 4 ("s "),IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s04, .transform_type = .identity, .suffix = PS.s00 },
    // [ 8] prefix=49 (""),  IDENTITY,       suffix= 3 (" of ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s03 },
    // [ 9] prefix=49 (""),  UPPERCASE_FIRST,suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s49 },
    // [10] prefix=49 (""),  IDENTITY,       suffix= 6 (" and ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s06 },
    // [11] prefix=49 (""),  OMIT_FIRST_2,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_2, .suffix = PS.s49 },
    // [12] prefix=49 (""),  OMIT_LAST_1,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_1, .suffix = PS.s49 },
    // [13] prefix= 1 (", "),IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s01, .transform_type = .identity, .suffix = PS.s00 },
    // [14] prefix=49 (""),  IDENTITY,       suffix= 1 (", ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s01 },
    // [15] prefix= 0 (" "), UPPERCASE_FIRST,suffix= 0 (" ")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s00 },
    // [16] prefix=49 (""),  IDENTITY,       suffix= 7 (" in ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s07 },
    // [17] prefix=49 (""),  IDENTITY,       suffix= 9 (" to ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s09 },
    // [18] prefix=48 ("e "),IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s48, .transform_type = .identity, .suffix = PS.s00 },
    // [19] prefix=49 (""),  IDENTITY,       suffix= 8 ("\"")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s08 },
    // [20] prefix=49 (""),  IDENTITY,       suffix= 5 (".")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s05 },
    // [21] prefix=49 (""),  IDENTITY,       suffix=10 ("\">")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s10 },
    // [22] prefix=49 (""),  IDENTITY,       suffix=11 ("\n")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s11 },
    // [23] prefix=49 (""),  OMIT_LAST_3,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_3, .suffix = PS.s49 },
    // [24] prefix=49 (""),  IDENTITY,       suffix=13 ("]")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s13 },
    // [25] prefix=49 (""),  IDENTITY,       suffix=14 (" for ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s14 },
    // [26] prefix=49 (""),  OMIT_FIRST_3,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_3, .suffix = PS.s49 },
    // [27] prefix=49 (""),  OMIT_LAST_2,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_2, .suffix = PS.s49 },
    // [28] prefix=49 (""),  IDENTITY,       suffix=15 (" a ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s15 },
    // [29] prefix=49 (""),  IDENTITY,       suffix=16 (" that ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s16 },
    // [30] prefix= 0 (" "), UPPERCASE_FIRST,suffix=49 ("")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s49 },
    // [31] prefix=49 (""),  IDENTITY,       suffix=12 (". ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s12 },
    // [32] prefix= 5 ("."), IDENTITY,       suffix=49 ("")
    .{ .prefix = PS.s05, .transform_type = .identity, .suffix = PS.s49 },
    // [33] prefix= 0 (" "), IDENTITY,       suffix= 1 (", ")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s01 },
    // [34] prefix=49 (""),  OMIT_FIRST_4,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_4, .suffix = PS.s49 },
    // [35] prefix=49 (""),  IDENTITY,       suffix=18 (" with ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s18 },
    // [36] prefix=49 (""),  IDENTITY,       suffix=17 ("'")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s17 },
    // [37] prefix=49 (""),  IDENTITY,       suffix=19 (" from ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s19 },
    // [38] prefix=49 (""),  IDENTITY,       suffix=20 (" by ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s20 },
    // [39] prefix=49 (""),  OMIT_FIRST_5,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_5, .suffix = PS.s49 },
    // [40] prefix=49 (""),  OMIT_FIRST_6,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_6, .suffix = PS.s49 },
    // [41] prefix=47 (" the "), IDENTITY,   suffix=49 ("")
    .{ .prefix = PS.s47, .transform_type = .identity, .suffix = PS.s49 },
    // [42] prefix=49 (""),  OMIT_LAST_4,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_4, .suffix = PS.s49 },
    // [43] prefix=49 (""),  IDENTITY,       suffix=22 (". The ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s22 },
    // [44] prefix=49 (""),  UPPERCASE_ALL,  suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s49 },
    // [45] prefix=49 (""),  IDENTITY,       suffix=23 (" on ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s23 },
    // [46] prefix=49 (""),  IDENTITY,       suffix=24 (" as ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s24 },
    // [47] prefix=49 (""),  IDENTITY,       suffix=25 (" is ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s25 },
    // [48] prefix=49 (""),  OMIT_LAST_7,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_7, .suffix = PS.s49 },
    // [49] prefix=49 (""),  OMIT_LAST_1,    suffix=26 ("ing ")
    .{ .prefix = PS.s49, .transform_type = .omit_last_1, .suffix = PS.s26 },
    // [50] prefix=49 (""),  IDENTITY,       suffix=27 ("\n\t")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s27 },
    // [51] prefix=49 (""),  IDENTITY,       suffix=28 (":")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s28 },
    // [52] prefix= 0 (" "), IDENTITY,       suffix=12 (". ")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s12 },
    // [53] prefix=49 (""),  IDENTITY,       suffix=29 ("ed ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s29 },
    // [54] prefix=49 (""),  OMIT_FIRST_9,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_9, .suffix = PS.s49 },
    // [55] prefix=49 (""),  OMIT_FIRST_7,   suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_first_7, .suffix = PS.s49 },
    // [56] prefix=49 (""),  OMIT_LAST_6,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_6, .suffix = PS.s49 },
    // [57] prefix=49 (""),  IDENTITY,       suffix=21 ("(")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s21 },
    // [58] prefix=49 (""),  UPPERCASE_FIRST,suffix= 1 (", ")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s01 },
    // [59] prefix=49 (""),  OMIT_LAST_8,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_8, .suffix = PS.s49 },
    // [60] prefix=49 (""),  IDENTITY,       suffix=31 (" at ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s31 },
    // [61] prefix=49 (""),  IDENTITY,       suffix=32 ("ly ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s32 },
    // [62] prefix=47 (" the "), IDENTITY,   suffix= 3 (" of ")
    .{ .prefix = PS.s47, .transform_type = .identity, .suffix = PS.s03 },
    // [63] prefix=49 (""),  OMIT_LAST_5,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_5, .suffix = PS.s49 },
    // [64] prefix=49 (""),  OMIT_LAST_9,    suffix=49 ("")
    .{ .prefix = PS.s49, .transform_type = .omit_last_9, .suffix = PS.s49 },
    // [65] prefix= 0 (" "), UPPERCASE_FIRST,suffix= 1 (", ")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s01 },
    // [66] prefix=49 (""),  UPPERCASE_FIRST,suffix= 8 ("\"")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s08 },
    // [67] prefix= 5 ("."), IDENTITY,       suffix=21 ("(")
    .{ .prefix = PS.s05, .transform_type = .identity, .suffix = PS.s21 },
    // [68] prefix=49 (""),  UPPERCASE_ALL,  suffix= 0 (" ")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s00 },
    // [69] prefix=49 (""),  UPPERCASE_FIRST,suffix=10 ("\">")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s10 },
    // [70] prefix=49 (""),  IDENTITY,       suffix=30 ("=\"")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s30 },
    // [71] prefix= 0 (" "), IDENTITY,       suffix= 5 (".")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s05 },
    // [72] prefix=35 (".com/"), IDENTITY,   suffix=49 ("")
    .{ .prefix = PS.s35, .transform_type = .identity, .suffix = PS.s49 },
    // [73] prefix=47 (" the "), IDENTITY,   suffix= 2 (" of the ")
    .{ .prefix = PS.s47, .transform_type = .identity, .suffix = PS.s02 },
    // [74] prefix=49 (""),  UPPERCASE_FIRST,suffix=17 ("'")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s17 },
    // [75] prefix=49 (""),  IDENTITY,       suffix=36 (". This ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s36 },
    // [76] prefix=49 (""),  IDENTITY,       suffix=33 (",")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s33 },
    // [77] prefix= 5 ("."), IDENTITY,       suffix= 0 (" ")
    .{ .prefix = PS.s05, .transform_type = .identity, .suffix = PS.s00 },
    // [78] prefix=49 (""),  UPPERCASE_FIRST,suffix=21 ("(")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s21 },
    // [79] prefix=49 (""),  UPPERCASE_FIRST,suffix= 5 (".")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s05 },
    // [80] prefix=49 (""),  IDENTITY,       suffix=37 (" not ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s37 },
    // [81] prefix= 0 (" "), IDENTITY,       suffix=30 ("=\"")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s30 },
    // [82] prefix=49 (""),  IDENTITY,       suffix=38 ("er ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s38 },
    // [83] prefix= 0 (" "), UPPERCASE_ALL,  suffix= 0 (" ")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s00 },
    // [84] prefix=49 (""),  IDENTITY,       suffix=39 ("al ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s39 },
    // [85] prefix= 0 (" "), UPPERCASE_ALL,  suffix=49 ("")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s49 },
    // [86] prefix=49 (""),  IDENTITY,       suffix=34 ("='")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s34 },
    // [87] prefix=49 (""),  UPPERCASE_ALL,  suffix= 8 ("\"")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s08 },
    // [88] prefix=49 (""),  UPPERCASE_FIRST,suffix=12 (". ")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s12 },
    // [89] prefix= 0 (" "), IDENTITY,       suffix=21 ("(")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s21 },
    // [90] prefix=49 (""),  IDENTITY,       suffix=40 ("ful ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s40 },
    // [91] prefix= 0 (" "), UPPERCASE_FIRST,suffix=12 (". ")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s12 },
    // [92] prefix=49 (""),  IDENTITY,       suffix=41 ("ive ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s41 },
    // [93] prefix=49 (""),  IDENTITY,       suffix=42 ("less ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s42 },
    // [94] prefix=49 (""),  UPPERCASE_ALL,  suffix=17 ("'")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s17 },
    // [95] prefix=49 (""),  IDENTITY,       suffix=43 ("est ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s43 },
    // [96] prefix= 0 (" "), UPPERCASE_FIRST,suffix= 5 (".")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s05 },
    // [97] prefix=49 (""),  UPPERCASE_ALL,  suffix=10 ("\">")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s10 },
    // [98] prefix= 0 (" "), IDENTITY,       suffix=34 ("='")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s34 },
    // [99] prefix=49 (""),  UPPERCASE_FIRST,suffix=33 (",")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s33 },
    // [100] prefix=49 (""), IDENTITY,       suffix=44 ("ize ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s44 },
    // [101] prefix=49 (""), UPPERCASE_ALL,  suffix= 5 (".")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s05 },
    // [102] prefix=45 ("\xC2\xA0"), IDENTITY, suffix=49 ("")
    .{ .prefix = PS.s45, .transform_type = .identity, .suffix = PS.s49 },
    // [103] prefix= 0 (" "),IDENTITY,       suffix=33 (",")
    .{ .prefix = PS.s00, .transform_type = .identity, .suffix = PS.s33 },
    // [104] prefix=49 (""), UPPERCASE_FIRST,suffix=30 ("=\"")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s30 },
    // [105] prefix=49 (""), UPPERCASE_ALL,  suffix=30 ("=\"")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s30 },
    // [106] prefix=49 (""), IDENTITY,       suffix=46 ("ous ")
    .{ .prefix = PS.s49, .transform_type = .identity, .suffix = PS.s46 },
    // [107] prefix=49 (""), UPPERCASE_ALL,  suffix= 1 (", ")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s01 },
    // [108] prefix=49 (""), UPPERCASE_FIRST,suffix=34 ("='")
    .{ .prefix = PS.s49, .transform_type = .ferment_first, .suffix = PS.s34 },
    // [109] prefix= 0 (" "),UPPERCASE_FIRST,suffix=33 (",")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s33 },
    // [110] prefix= 0 (" "),UPPERCASE_ALL,  suffix=30 ("=\"")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s30 },
    // [111] prefix= 0 (" "),UPPERCASE_ALL,  suffix= 1 (", ")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s01 },
    // [112] prefix=49 (""), UPPERCASE_ALL,  suffix=33 (",")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s33 },
    // [113] prefix=49 (""), UPPERCASE_ALL,  suffix=21 ("(")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s21 },
    // [114] prefix=49 (""), UPPERCASE_ALL,  suffix=12 (". ")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s12 },
    // [115] prefix= 0 (" "),UPPERCASE_ALL,  suffix= 5 (".")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s05 },
    // [116] prefix=49 (""), UPPERCASE_ALL,  suffix=34 ("='")
    .{ .prefix = PS.s49, .transform_type = .ferment_all, .suffix = PS.s34 },
    // [117] prefix= 0 (" "),UPPERCASE_ALL,  suffix=12 (". ")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s12 },
    // [118] prefix= 0 (" "),UPPERCASE_FIRST,suffix=30 ("=\"")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s30 },
    // [119] prefix= 0 (" "),UPPERCASE_ALL,  suffix=34 ("='")
    .{ .prefix = PS.s00, .transform_type = .ferment_all, .suffix = PS.s34 },
    // [120] prefix= 0 (" "),UPPERCASE_FIRST,suffix=34 ("='")
    .{ .prefix = PS.s00, .transform_type = .ferment_first, .suffix = PS.s34 },
};

// ── ToUpperCase (mirrors BrotliTransformDictionaryWord / ToUpperCase in C) ───

/// Uppercase a single UTF-8 codepoint starting at dst[pos].
/// Returns the number of bytes consumed.
fn toUpperCase(dst: []u8, pos: usize) usize {
    const b0 = dst[pos];
    if (b0 < 0xC0) {
        // 1-byte: flip bit 5 for ASCII a-z
        if (b0 >= 'a' and b0 <= 'z') {
            dst[pos] ^= 32;
        }
        return 1;
    }
    if (b0 < 0xE0) {
        // 2-byte UTF-8: flip bit 5 of second byte
        if (pos + 1 < dst.len) {
            dst[pos + 1] ^= 32;
        }
        return 2;
    }
    // 3-byte UTF-8: flip bits of third byte (arbitrary per RFC/brotli spec)
    if (pos + 2 < dst.len) {
        dst[pos + 2] ^= 5;
    }
    return 3;
}

/// Apply a single transform to `word`, writing prefix + transformed_word + suffix
/// into `output`.  Returns the number of bytes written.
pub fn applyTransform(word: []const u8, transform_id: u32, output: []u8) usize {
    const t = transforms[transform_id];
    var pos: usize = 0;

    // Copy prefix
    @memcpy(output[pos .. pos + t.prefix.len], t.prefix);
    pos += t.prefix.len;

    // Determine the word slice after omit_first / omit_last
    const word_start: usize = switch (t.transform_type) {
        .omit_first_1 => 1,
        .omit_first_2 => 2,
        .omit_first_3 => 3,
        .omit_first_4 => 4,
        .omit_first_5 => 5,
        .omit_first_6 => 6,
        .omit_first_7 => 7,
        .omit_first_8 => 8,
        .omit_first_9 => 9,
        else => 0,
    };
    const omit_last: usize = switch (t.transform_type) {
        .omit_last_1 => 1,
        .omit_last_2 => 2,
        .omit_last_3 => 3,
        .omit_last_4 => 4,
        .omit_last_5 => 5,
        .omit_last_6 => 6,
        .omit_last_7 => 7,
        .omit_last_8 => 8,
        .omit_last_9 => 9,
        else => 0,
    };

    const safe_start = @min(word_start, word.len);
    const safe_end = if (word.len > omit_last) word.len - omit_last else 0;
    const word_slice = if (safe_start <= safe_end) word[safe_start..safe_end] else word[safe_start..safe_start];

    // Copy word
    @memcpy(output[pos .. pos + word_slice.len], word_slice);

    // Apply case transforms
    switch (t.transform_type) {
        .ferment_first => {
            if (word_slice.len > 0) {
                _ = toUpperCase(output, pos);
            }
        },
        .ferment_all => {
            var i: usize = 0;
            var rem: usize = word_slice.len;
            while (rem > 0) {
                const step = toUpperCase(output, pos + i);
                i += step;
                if (step > rem) break;
                rem -= step;
            }
        },
        else => {},
    }
    pos += word_slice.len;

    // Copy suffix
    @memcpy(output[pos .. pos + t.suffix.len], t.suffix);
    pos += t.suffix.len;

    return pos;
}

// ── High-level dictionary word lookup ────────────────────────────────────────

/// Maximum backward reference distance where we look into the static dictionary.
/// (distance > max_backward_distance triggers dictionary lookup).
///
/// Given a distance code that resolves to a value > max_backward, decode the
/// dictionary reference:
///   word_id   = distance - max_backward - 1
///   word_index = word_id % nWords(copy_length)
///   transform  = word_id / nWords(copy_length)
///
/// Returns allocated slice; caller must free with allocator.free().
pub fn getDictionaryWord(
    allocator: std.mem.Allocator,
    distance: u32,
    copy_length: u8,
    max_distance: u32,
) ![]u8 {
    const word_id = distance - max_distance - 1;
    const n = nWords(copy_length);
    const word_index = word_id % n;
    const transform_id = word_id / n;

    const word = getWord(copy_length, word_index);

    // Maximum possible output length = prefix + word + suffix
    // Largest prefix/suffix is " of the " = 8 bytes, so word_len + 32 is safe
    const max_out = word.len + 64;
    const buf = try allocator.alloc(u8, max_out);
    const written = applyTransform(word, transform_id, buf);
    const result = try allocator.realloc(buf, written);
    return result;
}

// ── Unit tests ────────────────────────────────────────────────────────────────

test "getWord returns correct slice length" {
    // Word length 4, index 0 should return 4 bytes from the dictionary
    const w4 = getWord(4, 0);
    try std.testing.expectEqual(@as(usize, 4), w4.len);

    const w8 = getWord(8, 0);
    try std.testing.expectEqual(@as(usize, 8), w8.len);

    const w24 = getWord(24, 0);
    try std.testing.expectEqual(@as(usize, 24), w24.len);
}

test "getWord index bounds" {
    // nWords(4) = 1 << 10 = 1024; last valid index = 1023
    const last4 = getWord(4, nWords(4) - 1);
    try std.testing.expectEqual(@as(usize, 4), last4.len);

    // nWords(24) = 1 << 5 = 32; last valid index = 31
    const last24 = getWord(24, nWords(24) - 1);
    try std.testing.expectEqual(@as(usize, 24), last24.len);
}

test "transform identity preserves word" {
    // Transform 0 is identity with empty prefix and suffix
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 0, &out);
    try std.testing.expectEqualStrings(word, out[0..n]);
}

test "transform ferment_first uppercases first letter" {
    // Transform 4: prefix="", UPPERCASE_FIRST, suffix=" "
    // So "hello " (with trailing space from suffix)
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 4, &out);
    try std.testing.expectEqualStrings("Hello ", out[0..n]);
}

test "transform ferment_first on already uppercase" {
    // Transform 9: prefix="", UPPERCASE_FIRST, suffix=""
    const word = "World";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 9, &out);
    try std.testing.expectEqualStrings("World", out[0..n]);
}

test "transform ferment_all uppercases all letters" {
    // Transform 44: prefix="", UPPERCASE_ALL, suffix=""
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 44, &out);
    try std.testing.expectEqualStrings("HELLO", out[0..n]);
}

test "transform omit_first_1 drops first byte" {
    // Transform 3: prefix="", OMIT_FIRST_1, suffix=""
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 3, &out);
    try std.testing.expectEqualStrings("ello", out[0..n]);
}

test "transform omit_last_1 drops last byte" {
    // Transform 12: prefix="", OMIT_LAST_1, suffix=""
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 12, &out);
    try std.testing.expectEqualStrings("hell", out[0..n]);
}

test "transform omit_first_3" {
    // Transform 26: prefix="", OMIT_FIRST_3, suffix=""
    const word = "abcdef";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 26, &out);
    try std.testing.expectEqualStrings("def", out[0..n]);
}

test "transform omit_last_3" {
    // Transform 23: prefix="", OMIT_LAST_3, suffix=""
    const word = "abcdef";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 23, &out);
    try std.testing.expectEqualStrings("abc", out[0..n]);
}

test "transform with prefix and suffix" {
    // Transform 2: prefix=" ", IDENTITY, suffix=" "
    const word = "hello";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 2, &out);
    try std.testing.expectEqualStrings(" hello ", out[0..n]);
}

test "transform 62 prefix suffix combination" {
    // Transform 62: prefix=" the ", IDENTITY, suffix=" of "
    const word = "end";
    var out: [64]u8 = undefined;
    const n = applyTransform(word, 62, &out);
    try std.testing.expectEqualStrings(" the end of ", out[0..n]);
}
