#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <stdexcept>
#include <utility>
#include <vector>

namespace mcmesh::pixelupload
{
struct Span
{
	uint32_t		first;
	const uint32_t *pixels;
	size_t			count;
	double			scale = 1, offset = 0;
};
struct Row
{
	std::vector<uint32_t> pixels;
	int					  first, left, right; // Storage origin and the staged dirty interval.
};
struct Rect
{
	int x, y, width, height;
};

// The 16K atlas is a virtual image. Allocate CPU pixels only for rows that have
// actually been written; never allocate a second dense 1 GiB image at startup.
// Published rows are read by the device-restoration callback. Pending ranges
// stay private until the renderer has drained older consumers.
class Image
{
	int								   width_, height_;
	std::vector<std::vector<uint32_t>> rows_;
	size_t							   backingBytes_ = 0;

public:
	std::map<int, Row> pending;
	Image(int width, int height) : width_(width), height_(height), rows_(height) {}
	int	   width() const { return width_; }
	int	   height() const { return height_; }
	size_t backingBytes() const { return backingBytes_; }
	size_t pendingBytes() const
	{
		size_t bytes = 0;
		for (const auto &[y, row] : pending)
			bytes += row.pixels.capacity() * sizeof(uint32_t);
		return bytes;
	}
	const std::vector<uint32_t> &row(int y) const { return rows_[y]; }
	void						 validate(const Span &input) const
	{
		const auto capacity = uint64_t(width_) * height_;
		if (!input.pixels || !input.count || input.count > capacity || input.first >= capacity || !std::isfinite(input.scale) || input.scale < 1 || input.scale > 5 || !std::isfinite(input.offset) || input.offset < 0 || input.offset > 4 || std::floor(((uint64_t(input.first) + input.count - 1) / width_) * input.scale + input.offset) >= height_)
			throw std::runtime_error("l2_texture_target_bounds");
	}
	template <class Fn>
	void segments(const Span &input, Fn fn) const
	{
		for (size_t i = 0; i < input.count;)
		{
			const auto	 address = uint64_t(input.first) + i;
			const int	 x = int(address % width_);
			const int	 y = int(std::floor((address / width_) * input.scale + input.offset));
			const size_t count = std::min(input.count - i, size_t(width_ - x));
			fn(x, y, i, count);
			i += count;
		}
	}
	void prepare(const Span &input)
	{
		segments(input, [&](int x, int y, size_t, size_t count)
				 {
            const auto found = pending.find(y);
            if (found == pending.end()) {
                if (rows_[y].empty()) {
                    rows_[y].resize(width_, 0);
                    backingBytes_ += rows_[y].capacity() * sizeof(uint32_t);
                }
                pending.emplace(y, Row{std::vector<uint32_t>(rows_[y].begin() + x,
                    rows_[y].begin() + x + count), x, width_, 0});
                return;
            }
            auto& row = found->second;
            const int end = x + int(count);
            const int oldEnd = row.first + int(row.pixels.size());
            if (x >= row.first && end <= oldEnd) return;
            const int first = std::min(x, row.first);
            const int required = std::max(end, oldEnd) - first;
            const auto growth = row.pixels.size() > size_t(width_) / 4
                ? size_t(width_) : row.pixels.size() * 4;
            const int size = int(std::max(size_t(required), growth));
            const int origin = std::min(first, width_ - size);
            // Seed gaps from the published image, then retain earlier staged
            // writes. Allocate before changing the old range so failure cannot
            // corrupt a pending transaction. Geometric growth bounds recopying.
            std::vector<uint32_t> pixels(rows_[y].begin() + origin, rows_[y].begin() + origin + size);
            if (row.left < row.right)
                std::copy_n(row.pixels.data() + row.left - row.first, row.right - row.left,
                    pixels.data() + row.left - origin);
            row.pixels.swap(pixels);
            row.first = origin; });
	}
	void stagePrepared(const Span &input)
	{
		segments(input, [&](int x, int y, size_t first, size_t count)
				 {
            auto& row = pending.at(y);
            std::copy_n(input.pixels + first, count, row.pixels.data() + x - row.first);
            row.left = std::min(row.left, x);
            row.right = std::max(row.right, x + int(count)); });
	}
	void stage(const std::vector<Span> &inputs)
	{
		for (const auto &input : inputs)
			validate(input);
		for (const auto &input : inputs)
			prepare(input);
		for (const auto &input : inputs)
			stagePrepared(input);
	}
	std::vector<Rect> rectangles() const
	{
		std::vector<Rect> rects;
		for (const auto &[y, row] : pending)
		{
			if (row.left == row.right || row.left > row.right)
				continue;
			if (!rects.empty() && y == rects.back().y + rects.back().height)
			{
				auto	 &rect = rects.back();
				const int right = std::max(rect.x + rect.width, row.right);
				rect.x = std::min(rect.x, row.left);
				rect.width = right - rect.x;
				++rect.height;
			}
			else
				rects.push_back({row.left, y, row.right - row.left, 1});
		}
		return rects;
	}
	void publish()
	{
		for (const auto &[y, row] : pending)
			if (row.left < row.right)
				std::copy_n(row.pixels.data() + row.left - row.first, row.right - row.left,
							rows_[y].data() + row.left);
	}
};
} // namespace mcmesh::pixelupload
