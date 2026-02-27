const std = @import("std");

// --- Search Types ---

pub const SearchResult = struct {
    chunk_id: u64,
    text: []const u8,
    score: f64,
    source_file: ?[]const u8 = null,
    chunk_index: u32 = 0,
    vector_score: f64 = 0.0,
    text_score: f64 = 0.0,
};

pub const SearchConfig = struct {
    vector_weight: f64 = 0.7,
    text_weight: f64 = 0.3,
    mmr_lambda: f64 = 0.7,
    temporal_decay_half_life_days: f64 = 30.0,
    max_results: u32 = 10,
    min_score: f64 = 0.0,
};

// --- Hybrid Scoring ---

/// Compute hybrid score: vectorWeight * vecScore + textWeight * textScore
pub fn hybridScore(vec_score: f64, text_score: f64, config: SearchConfig) f64 {
    return config.vector_weight * vec_score + config.text_weight * text_score;
}

/// Apply temporal decay to a score based on document age.
/// Uses exponential decay: score * exp(-lambda * age_days)
/// where lambda = ln(2) / half_life_days
pub fn applyTemporalDecay(score: f64, age_days: f64, half_life_days: f64) f64 {
    if (half_life_days <= 0.0) return score;
    if (age_days <= 0.0) return score;
    const lambda = @log(2.0) / half_life_days;
    return score * @exp(-lambda * age_days);
}

/// Compute Maximal Marginal Relevance (MMR) for diversification.
/// MMR = lambda * sim(doc, query) - (1 - lambda) * max(sim(doc, selected))
pub fn mmrScore(
    relevance: f64,
    max_similarity_to_selected: f64,
    lambda: f64,
) f64 {
    return lambda * relevance - (1.0 - lambda) * max_similarity_to_selected;
}

/// Re-rank results using MMR to diversify.
/// Returns indices in MMR-ranked order.
pub fn mmrRerank(
    allocator: std.mem.Allocator,
    scores: []const f64,
    similarities: []const []const f64,
    lambda: f64,
    max_results: usize,
) ![]usize {
    const n = scores.len;
    if (n == 0) return &.{};

    var selected = std.ArrayListUnmanaged(usize){};
    var available = std.ArrayListUnmanaged(bool){};
    try available.resize(allocator, n);
    @memset(available.items, true);

    const count = @min(n, max_results);

    // First: pick highest scoring document
    var best_idx: usize = 0;
    var best_score: f64 = -std.math.inf(f64);
    for (scores, 0..) |s, i| {
        if (s > best_score) {
            best_score = s;
            best_idx = i;
        }
    }
    try selected.append(allocator, best_idx);
    available.items[best_idx] = false;

    // Then: iteratively pick best MMR candidate
    while (selected.items.len < count) {
        var best_mmr: f64 = -std.math.inf(f64);
        var best_mmr_idx: usize = 0;
        var found = false;

        for (0..n) |i| {
            if (!available.items[i]) continue;

            // Find max similarity to already-selected documents
            var max_sim: f64 = 0.0;
            for (selected.items) |sel_idx| {
                if (i < similarities.len and sel_idx < similarities[i].len) {
                    const sim = similarities[i][sel_idx];
                    if (sim > max_sim) max_sim = sim;
                }
            }

            const m = mmrScore(scores[i], max_sim, lambda);
            if (m > best_mmr or !found) {
                best_mmr = m;
                best_mmr_idx = i;
                found = true;
            }
        }

        if (!found) break;
        try selected.append(allocator, best_mmr_idx);
        available.items[best_mmr_idx] = false;
    }

    available.deinit(allocator);
    return selected.toOwnedSlice(allocator);
}

/// Free MMR indices returned by mmrRerank.
pub fn freeIndices(allocator: std.mem.Allocator, indices: []usize) void {
    allocator.free(indices);
}

// --- Cosine Similarity ---

pub fn cosineSimilarity(a: []const f64, b: []const f64) f64 {
    if (a.len != b.len or a.len == 0) return 0.0;

    var dot: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;

    for (a, b) |va, vb| {
        dot += va * vb;
        norm_a += va * va;
        norm_b += vb * vb;
    }

    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0.0) return 0.0;
    return dot / denom;
}

// --- Tests ---

test "hybridScore" {
    const config = SearchConfig{};
    const score = hybridScore(0.9, 0.8, config);
    // 0.7 * 0.9 + 0.3 * 0.8 = 0.63 + 0.24 = 0.87
    try std.testing.expectApproxEqAbs(@as(f64, 0.87), score, 0.001);
}

test "hybridScore vector only" {
    const score = hybridScore(1.0, 0.0, .{ .vector_weight = 1.0, .text_weight = 0.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "hybridScore text only" {
    const score = hybridScore(0.0, 1.0, .{ .vector_weight = 0.0, .text_weight = 1.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "applyTemporalDecay" {
    // No decay at age 0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), applyTemporalDecay(1.0, 0.0, 30.0), 0.001);

    // Half score at half-life
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), applyTemporalDecay(1.0, 30.0, 30.0), 0.001);

    // Quarter at 2x half-life
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), applyTemporalDecay(1.0, 60.0, 30.0), 0.001);

    // No decay with 0 half-life
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), applyTemporalDecay(1.0, 100.0, 0.0), 0.001);
}

test "mmrScore" {
    // High relevance, low similarity to selected → high MMR
    const high_mmr = mmrScore(0.9, 0.1, 0.7);
    // 0.7 * 0.9 - 0.3 * 0.1 = 0.63 - 0.03 = 0.6
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), high_mmr, 0.001);

    // High relevance, high similarity → lower MMR
    const low_mmr = mmrScore(0.9, 0.9, 0.7);
    // 0.7 * 0.9 - 0.3 * 0.9 = 0.63 - 0.27 = 0.36
    try std.testing.expectApproxEqAbs(@as(f64, 0.36), low_mmr, 0.001);
}

test "cosineSimilarity identical" {
    const a = [_]f64{ 1.0, 0.0, 0.0 };
    const b = [_]f64{ 1.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity orthogonal" {
    const a = [_]f64{ 1.0, 0.0 };
    const b = [_]f64{ 0.0, 1.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity opposite" {
    const a = [_]f64{ 1.0, 0.0 };
    const b = [_]f64{ -1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity empty" {
    const a = [_]f64{};
    const b = [_]f64{};
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity different lengths" {
    const a = [_]f64{ 1.0, 2.0 };
    const b = [_]f64{ 1.0, 2.0, 3.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineSimilarity(&a, &b), 0.001);
}

test "mmrRerank basic" {
    const allocator = std.testing.allocator;

    const scores = [_]f64{ 0.9, 0.8, 0.7 };
    const sim_0 = [_]f64{ 1.0, 0.5, 0.2 };
    const sim_1 = [_]f64{ 0.5, 1.0, 0.3 };
    const sim_2 = [_]f64{ 0.2, 0.3, 1.0 };
    const similarities = [_][]const f64{ &sim_0, &sim_1, &sim_2 };

    const indices = try mmrRerank(allocator, &scores, &similarities, 0.7, 3);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 3), indices.len);
    // First should be highest scoring
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
}

test "mmrRerank max results limit" {
    const allocator = std.testing.allocator;

    const scores = [_]f64{ 0.9, 0.8, 0.7, 0.6, 0.5 };
    const indices = try mmrRerank(allocator, &scores, &.{}, 0.7, 2);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 2), indices.len);
}

test "mmrRerank empty" {
    const allocator = std.testing.allocator;
    const indices = try mmrRerank(allocator, &.{}, &.{}, 0.7, 10);
    try std.testing.expectEqual(@as(usize, 0), indices.len);
}

test "SearchConfig defaults" {
    const config = SearchConfig{};
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), config.vector_weight, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), config.text_weight, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), config.mmr_lambda, 0.001);
    try std.testing.expectEqual(@as(u32, 10), config.max_results);
}

test "SearchResult" {
    const result = SearchResult{
        .chunk_id = 42,
        .text = "test chunk",
        .score = 0.85,
        .vector_score = 0.9,
        .text_score = 0.7,
        .source_file = "docs/readme.md",
    };
    try std.testing.expectEqual(@as(u64, 42), result.chunk_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), result.score, 0.001);
}

// --- Additional Tests ---

test "hybridScore equal weights" {
    const score = hybridScore(0.6, 0.8, .{ .vector_weight = 0.5, .text_weight = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), score, 0.001);
}

test "hybridScore zero scores" {
    const score = hybridScore(0.0, 0.0, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), score, 0.001);
}

test "hybridScore perfect scores" {
    const score = hybridScore(1.0, 1.0, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "applyTemporalDecay negative half life returns score unchanged" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), applyTemporalDecay(0.8, 10.0, -1.0), 0.001);
}

test "applyTemporalDecay negative age returns score unchanged" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), applyTemporalDecay(0.8, -5.0, 30.0), 0.001);
}

test "applyTemporalDecay very old document nearly zero" {
    const decayed = applyTemporalDecay(1.0, 300.0, 30.0);
    try std.testing.expect(decayed < 0.01);
}

test "applyTemporalDecay starting score preserved" {
    const decayed = applyTemporalDecay(0.5, 30.0, 30.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), decayed, 0.001);
}

test "mmrScore lambda 1 ignores similarity" {
    const score = mmrScore(0.9, 0.9, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), score, 0.001);
}

test "mmrScore lambda 0 diversity only" {
    const score = mmrScore(0.9, 0.5, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), score, 0.001);
}

test "cosineSimilarity similar vectors" {
    const a = [_]f64{ 1.0, 2.0, 3.0 };
    const b = [_]f64{ 1.0, 2.0, 3.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity zero vector" {
    const a = [_]f64{ 0.0, 0.0, 0.0 };
    const b = [_]f64{ 1.0, 2.0, 3.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity partially similar" {
    const a = [_]f64{ 1.0, 0.0 };
    const b = [_]f64{ 1.0, 1.0 };
    // cos(45 deg) = ~0.707
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f64, 0.707), sim, 0.01);
}

test "mmrRerank single document" {
    const allocator = std.testing.allocator;
    const scores = [_]f64{0.9};
    const indices = try mmrRerank(allocator, &scores, &.{}, 0.7, 5);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 1), indices.len);
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
}

test "SearchResult defaults" {
    const result = SearchResult{
        .chunk_id = 0,
        .text = "",
        .score = 0.0,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), result.source_file);
    try std.testing.expectEqual(@as(u32, 0), result.chunk_index);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.vector_score, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.text_score, 0.001);
}

test "SearchConfig custom values" {
    const config = SearchConfig{
        .vector_weight = 0.5,
        .text_weight = 0.5,
        .mmr_lambda = 0.9,
        .temporal_decay_half_life_days = 60.0,
        .max_results = 5,
        .min_score = 0.1,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), config.vector_weight, 0.001);
    try std.testing.expectEqual(@as(u32, 5), config.max_results);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), config.min_score, 0.001);
}

// --- New Tests ---

test "hybridScore negative vector score" {
    const score = hybridScore(-0.5, 0.8, .{});
    // 0.7 * -0.5 + 0.3 * 0.8 = -0.35 + 0.24 = -0.11
    try std.testing.expectApproxEqAbs(@as(f64, -0.11), score, 0.001);
}

test "hybridScore large weights" {
    const score = hybridScore(0.5, 0.5, .{ .vector_weight = 10.0, .text_weight = 10.0 });
    // 10 * 0.5 + 10 * 0.5 = 10
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), score, 0.001);
}

test "hybridScore asymmetric weights" {
    const score = hybridScore(1.0, 1.0, .{ .vector_weight = 0.9, .text_weight = 0.1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "applyTemporalDecay quarter life" {
    // At 15 days with 30-day half-life: score * 2^(-15/30) = 2^(-0.5) = ~0.707
    const decayed = applyTemporalDecay(1.0, 15.0, 30.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.707), decayed, 0.01);
}

test "applyTemporalDecay score of 2.0" {
    const decayed = applyTemporalDecay(2.0, 30.0, 30.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), decayed, 0.001);
}

test "applyTemporalDecay very short half life" {
    const decayed = applyTemporalDecay(1.0, 10.0, 1.0);
    try std.testing.expect(decayed < 0.01);
}

test "applyTemporalDecay very long half life" {
    const decayed = applyTemporalDecay(1.0, 1.0, 10000.0);
    // Should be very close to 1.0 with such a long half-life
    try std.testing.expect(decayed > 0.99);
}

test "mmrScore balanced lambda" {
    const score = mmrScore(0.8, 0.4, 0.5);
    // 0.5 * 0.8 - 0.5 * 0.4 = 0.4 - 0.2 = 0.2
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), score, 0.001);
}

test "mmrScore zero relevance" {
    const score = mmrScore(0.0, 0.5, 0.7);
    // 0.7 * 0 - 0.3 * 0.5 = -0.15
    try std.testing.expectApproxEqAbs(@as(f64, -0.15), score, 0.001);
}

test "mmrScore negative similarity" {
    const score = mmrScore(0.8, -0.3, 0.7);
    // 0.7 * 0.8 - 0.3 * (-0.3) = 0.56 + 0.09 = 0.65
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), score, 0.001);
}

test "cosineSimilarity negative vectors" {
    const a = [_]f64{ -1.0, -2.0 };
    const b = [_]f64{ -1.0, -2.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity large dimension" {
    var a: [100]f64 = undefined;
    var b: [100]f64 = undefined;
    for (0..100) |i| {
        a[i] = @as(f64, @floatFromInt(i));
        b[i] = @as(f64, @floatFromInt(i));
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosineSimilarity(&a, &b), 0.001);
}

test "cosineSimilarity unit vectors at 60 degrees" {
    // cos(60) = 0.5
    const a = [_]f64{ 1.0, 0.0 };
    const b = [_]f64{ 0.5, @sqrt(3.0) / 2.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sim, 0.01);
}

test "cosineSimilarity both zero" {
    const a = [_]f64{ 0.0, 0.0, 0.0 };
    const b = [_]f64{ 0.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosineSimilarity(&a, &b), 0.001);
}

test "mmrRerank two documents with high similarity" {
    const allocator = std.testing.allocator;

    const scores = [_]f64{ 0.9, 0.85 };
    const sim_0 = [_]f64{ 1.0, 0.99 };
    const sim_1 = [_]f64{ 0.99, 1.0 };
    const similarities = [_][]const f64{ &sim_0, &sim_1 };

    const indices = try mmrRerank(allocator, &scores, &similarities, 0.7, 2);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 2), indices.len);
    // First pick: index 0 (highest score)
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
}

test "mmrRerank with zero lambda selects most diverse" {
    const allocator = std.testing.allocator;

    const scores = [_]f64{ 0.9, 0.8, 0.1 };
    const sim_0 = [_]f64{ 1.0, 0.9, 0.1 };
    const sim_1 = [_]f64{ 0.9, 1.0, 0.2 };
    const sim_2 = [_]f64{ 0.1, 0.2, 1.0 };
    const similarities = [_][]const f64{ &sim_0, &sim_1, &sim_2 };

    const indices = try mmrRerank(allocator, &scores, &similarities, 0.0, 3);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 3), indices.len);
    // First pick is still highest score
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
    // Second pick should prefer most diverse (index 2)
    try std.testing.expectEqual(@as(usize, 2), indices[1]);
}

test "mmrRerank max results one from many" {
    const allocator = std.testing.allocator;
    const scores = [_]f64{ 0.5, 0.9, 0.3 };
    const indices = try mmrRerank(allocator, &scores, &.{}, 0.7, 1);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 1), indices.len);
    // Should pick index 1 (highest score 0.9)
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
}

test "mmrRerank equal scores" {
    const allocator = std.testing.allocator;
    const scores = [_]f64{ 0.5, 0.5, 0.5 };
    const indices = try mmrRerank(allocator, &scores, &.{}, 0.7, 3);
    defer freeIndices(allocator, indices);

    try std.testing.expectEqual(@as(usize, 3), indices.len);
}

test "SearchResult with all fields" {
    const result = SearchResult{
        .chunk_id = 100,
        .text = "complete test",
        .score = 0.95,
        .source_file = "src/main.zig",
        .chunk_index = 5,
        .vector_score = 0.98,
        .text_score = 0.88,
    };
    try std.testing.expectEqual(@as(u64, 100), result.chunk_id);
    try std.testing.expectEqualStrings("complete test", result.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), result.score, 0.001);
    try std.testing.expectEqualStrings("src/main.zig", result.source_file.?);
    try std.testing.expectEqual(@as(u32, 5), result.chunk_index);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), result.vector_score, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.88), result.text_score, 0.001);
}

test "SearchConfig min_score default" {
    const config = SearchConfig{};
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), config.min_score, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), config.temporal_decay_half_life_days, 0.001);
}

test "cosineSimilarity symmetric" {
    const a = [_]f64{ 1.0, 2.0, 3.0 };
    const b = [_]f64{ 4.0, 5.0, 6.0 };
    const sim_ab = cosineSimilarity(&a, &b);
    const sim_ba = cosineSimilarity(&b, &a);
    try std.testing.expectApproxEqAbs(sim_ab, sim_ba, 0.001);
}

test "freeIndices empty" {
    const allocator = std.testing.allocator;
    const indices = try allocator.alloc(usize, 0);
    freeIndices(allocator, indices);
}
