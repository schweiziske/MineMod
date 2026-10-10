#include "../pixel_texture_data.h"
#include <iostream>
#include <random>

using namespace mcmesh::pixelupload;
void check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void compare(const Image& image, const std::vector<uint32_t>& expected, const char* message) {
    for (int y = 0; y < image.height(); ++y) {
        const auto& row = image.row(y);
        for (int x = 0; x < image.width(); ++x)
            check((row.empty() ? 0 : row[x]) == expected[size_t(y) * image.width() + x], message);
    }
}
void apply(std::vector<uint32_t>& expected, int width, const std::vector<Span>& spans) {
    for (const auto& span : spans) for (size_t i = 0; i < span.count; ++i) {
        const auto address = span.first + i;
        const auto y = size_t(std::floor((address / width) * span.scale + span.offset));
        expected[y * width + address % width] = span.pixels[i];
    }
}
void rangeGrowthAndRetry() {
    Image image(16384, 5);
    std::vector<uint32_t> original(16384 * 5);
    for (size_t i = 0; i < original.size(); ++i) original[i] = uint32_t(i * 17 + 9);
    image.stage({{0, original.data(), original.size()}});
    image.publish(); image.pending.clear();
    const uint32_t replacement = 0x01020304u;
    auto expected = original;
    for (const unsigned x : {8192u, 8191u, 12000u, 2000u, 16383u, 0u, 9000u, 8192u}) {
        const std::vector<Span> spans{{x, &replacement, 1}};
        image.stage(spans);
        apply(expected, image.width(), spans);
        compare(image, original, "growing pending ranges changed published pixels");
    }
    image.prepare({16384 + 777, &replacement, 1});
    const auto plan = image.rectangles();
    check(plan.size() == 1 && plan[0].y == 0 && plan[0].x == 0 && plan[0].width == 16384,
        "prepare without staging introduced a dirty rectangle");
    image.publish();
    compare(image, expected, "range growth lost pending writes or untouched gaps");
    image.publish();
    compare(image, expected, "retrying publication changed the pending version");
    // Simulate a Download failure: pending stays alive after publication. Restore
    // the old bytes through that same object before the transaction is discarded.
    image.stage({{0, original.data(), 16384}});
    image.publish(); image.pending.clear();
    compare(image, original, "rollback after a failed upload did not restore old bytes");
}
void randomizedDenseOracle() {
    constexpr unsigned Width = 67, Height = 40;
    Image image(Width, Height);
    std::vector<uint32_t> published(Width * Height), expected = published;
    std::mt19937 random(0x50495845u);
    for (unsigned batch = 0; batch < 2000; ++batch) {
        for (unsigned update = 0, updates = random() % 8 + 1; update < updates; ++update) {
            const auto first = random() % (Width * 4);
            std::vector<uint32_t> colors(random() % (Width * 3) + 1);
            for (auto& color : colors) color = random();
            const unsigned mode = random() % 3;
            const double scale = mode == 0 ? 1 : mode == 1 ? 1.25 : 5;
            const double offset = mode == 0 ? 0 : mode == 1 ? 0.625 : 2;
            const std::vector<Span> spans{{first, colors.data(), colors.size(), scale, offset}};
            image.stage(spans);
            apply(expected, Width, spans);
            if ((batch + update) % 17 == 0) {
                const auto before = image.pendingBytes();
                bool rejected = false;
                try { image.stage({{0, colors.data(), 1}, {Width * Height - 1, colors.data(), 2}}); }
                catch (const std::runtime_error&) { rejected = true; }
                check(rejected && image.pendingBytes() == before, "invalid batch changed its pending ranges");
            }
            compare(image, published, "random staging leaked into the published image");
        }
        const auto plan = image.rectangles();
        image.publish();
        compare(image, expected, "sparse publication differs from the dense pixel oracle");
        for (const auto& rect : plan)
            check(rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0
                && rect.x + rect.width <= int(Width) && rect.y + rect.height <= int(Height),
                "random dirty rectangle escaped the texture");
        if (batch % 11 == 0) {
            image.publish();
            compare(image, expected, "random publication was not idempotent");
        }
        image.pending.clear();
        published = expected;
        check(image.pendingBytes() == 0, "cleared transaction retained pending pixel bytes");
    }
}
int main() {
    try {
        Image image(16384, 16384);
        check(image.backingBytes() == 0 && image.row(123).empty(), "empty atlas allocated dense pixels");
        const uint32_t colors[]{0, 0xffffffffu, 0x01020304u};
        image.stage({{16383, colors, 3}});
        check(image.backingBytes() == 2 * 16384 * 4 && image.pendingBytes() <= 64,
            "three pending texels allocated complete 16K rows");
        check(image.row(0)[16383] == 0 && image.row(1)[0] == 0, "pending pixels leaked into device restoration");
        bool rejected = false;
        try { image.stage({{0, colors, 1}, {268435455, colors, 2}}); }
        catch (const std::runtime_error&) { rejected = true; }
        check(rejected, "invalid second span was accepted");
        image.publish();
        image.pending.clear();
        check(image.row(0)[0] == 0 && image.row(0)[16383] == 0 && image.row(1)[0] == 0xffffffffu && image.row(1)[1] == 0x01020304u,
            "row boundary or alpha bytes changed");
        const uint32_t replacement = 0x12345678u;
        image.stage({{16384, &replacement, 1}});
        image.stage({{16385, colors, 1}});
        check(image.row(1)[0] == 0xffffffffu, "staged replacement changed published version");
        const auto rects = image.rectangles();
        check(rects.size() == 1 && rects[0].x == 0 && rects[0].y == 1 && rects[0].width == 2,
            "overlapping writes did not coalesce");
        image.publish(); image.pending.clear();
        check(image.row(1)[0] == replacement && image.row(1)[1] == 0, "coalesced writes were lost");
        const uint32_t lastQuad = 16384u * (16384u / 5) - 1;
        const uint32_t corners[]{1, 2, 3, 4};
        image.stage({{lastQuad * 4, corners, 4, 1.25, 0.625}, {lastQuad, &replacement, 1, 5, 2}});
        image.publish(); image.pending.clear();
        check(image.row(16379)[16383] == 4 && image.row(16377)[16383] == replacement,
            "last complete five-row group was truncated");
        check(image.row(16383).empty(), "unused tail rows acquired backing storage");
        rangeGrowthAndRetry();
        randomizedDenseOracle();
        std::cout << "PASS: compact pending ranges, 2000 dense-oracle batches, retry/rollback, 16K boundaries and immutable publication\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
