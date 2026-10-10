// Measures the actual constructor/destructor and heap work on the submitting
// thread. No Lua, Source API, worker queue or GPU timing is included.
#include "../l2_core.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <new>
#include <stdexcept>
#include <string>

namespace {
bool counting = false;
size_t allocations = 0, allocatedBytes = 0;
volatile size_t sink = 0;
}
void* operator new(size_t size) {
    if (void* memory = std::malloc(size ? size : 1)) {
        if (counting) { ++allocations; allocatedBytes += size; }
        return memory;
    }
    throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, size_t) noexcept { std::free(memory); }
void* operator new[](size_t size) { return ::operator new(size); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory, size_t) noexcept { std::free(memory); }

namespace {
using namespace mcmesh::l2;
struct Source : CellSource {
    Cell read(int, int, int) const override { return {1048576u + 240, 1}; }
    size_t bytes() const override { return sizeof(*this); }
};
Cell callback(void*, int, int, int) { return {1048576u + 240, 1}; }
struct Sample { double micros = 0, allocations = 0, allocatedBytes = 0; };
Sample measure(unsigned iterations, bool owned, const std::shared_ptr<const Source>& source) {
    const int origin[3] = {-2,-2,-2}, dimensions[3] = {20,20,20};
    allocations = allocatedBytes = 0;
    const auto start = std::chrono::steady_clock::now();
    counting = true;
    for (unsigned i = 0; i < iterations; ++i) {
        if (owned) {
            Snapshot snapshot(origin, dimensions, source);
            sink = snapshot.bytes();
        } else {
            Snapshot snapshot(origin, dimensions, callback, nullptr);
            sink = snapshot.bytes();
        }
    }
    counting = false;
    return {std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count() / iterations,
        double(allocations) / iterations, double(allocatedBytes) / iterations};
}
}
int main(int argc, char** argv) {
    try {
        const unsigned iterations = argc > 1 ? unsigned(std::stoul(argv[1])) : 50000;
        if (iterations < 1000 || iterations > 1000000) throw std::runtime_error("iterations must be 1000..1000000");
        const auto source = std::make_shared<const Source>();
        std::cout << std::fixed << std::setprecision(4) << "{\"iterations\":" << iterations << ",\"cells\":8000";
        for (const bool owned : {true, false}) {
            measure(1000, owned, source);
            std::vector<Sample> samples;
            for (unsigned i = 0; i < 7; ++i) samples.push_back(measure(iterations, owned, source));
            std::sort(samples.begin(), samples.end(), [](const auto& a, const auto& b) { return a.micros < b.micros; });
            const auto& sample = samples[samples.size() / 2];
            std::cout << ",\"" << (owned ? "owned" : "callback") << "\":{\"micros\":" << sample.micros
                << ",\"allocations\":" << sample.allocations << ",\"allocatedBytes\":" << sample.allocatedBytes << "}";
        }
        std::cout << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
