#include "World/WorldSession.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace mcmesh::world;
namespace
{
void check(bool ok, const char *text)
{
	if (!ok)
		throw std::runtime_error(text);
}
template <class F>
void rejects(F fn, const char *text)
{
	bool failed = false;
	try
	{
		fn();
	}
	catch (const std::exception &)
	{
		failed = true;
	}
	check(failed, text);
}
using Bytes = std::vector<uint8_t>;
void u16(Bytes &out, unsigned v)
{
	out.push_back(uint8_t(v));
	out.push_back(uint8_t(v >> 8));
}
void u32(Bytes &out, uint32_t v)
{
	for (unsigned i = 0; i < 4; ++i)
		out.push_back(uint8_t(v >> (8 * i)));
}
Bytes header(unsigned chunks, unsigned count)
{
	Bytes out{'M', 'C', 'B', '9', 1, 16, 32, 2};
	u16(out, chunks);
	u32(out, count);
	return out;
}
void chunkHeader(Bytes &out, int x, unsigned flags = 0, unsigned entities = 0)
{
	u32(out, uint32_t(x));
	u32(out, 0);
	u32(out, 1);
	out.push_back(uint8_t(flags));
	u16(out, entities);
}
void packed(Bytes &out, unsigned bits, const std::vector<uint32_t> &palette,
			const std::vector<unsigned> &indices)
{
	unsigned count = 0;
	for (auto i : indices)
		count += palette[i] != 0;
	out.push_back(2);
	u16(out, count);
	out.push_back(uint8_t(bits));
	u16(out, unsigned(palette.size()));
	for (auto state : palette)
		u32(out, state);
	std::vector<uint32_t> words((4096 * bits + 31) / 32);
	for (unsigned i = 0; i < 4096; ++i)
	{
		const unsigned bit = i * bits, at = bit / 32, shift = bit % 32;
		words[at] |= indices[i] << shift;
		if (shift + bits > 32)
			words[at + 1] |= indices[i] >> (32 - shift);
	}
	u16(out, unsigned(words.size()));
	for (auto word : words)
		u32(out, word);
}
std::shared_ptr<Catalog> catalog()
{
	auto result = std::make_shared<Catalog>();
	result->states.resize(4096);
	for (unsigned i = 1; i < 4096; ++i)
		result->states[i] = {0, 15, 16, 0xef000, 9, 0.2f};
	result->contextual.resize(result->states.size());
	result->contextual[3] = 1;
	result->mBlockEntityStates.resize(result->states.size());
	result->mBlockEntityStates[3] = 1;
	return result;
}
DecodeInput input(Bytes bytes, unsigned chunks, unsigned cells, std::shared_ptr<const Catalog> profiles)
{
	DecodeInput out;
	out.catalog = std::move(profiles);
	out.epoch = 1;
	out.metadata = {0, uint32_t(bytes.size()), 7, 13, chunks, cells};
	out.payload = std::move(bytes);
	return out;
}
Bytes unhex(const char *text)
{
	Bytes result;
	auto  digit = [](char c)
	{
		return c <= '9' ? c - '0' : c - 'a' + 10;
	};
	for (unsigned i = 0; text[i]; i += 2)
		result.push_back(uint8_t(digit(text[i]) * 16 + digit(text[i + 1])));
	return result;
}
DecodeStatus ready(DecodeWorker &worker, uint64_t id)
{
	const auto limit = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	for (;;)
	{
		auto status = worker.poll(id);
		if (status.state != DecodeState::Queued && status.state != DecodeState::Running)
			return status;
		check(std::chrono::steady_clock::now() < limit, "decode worker timeout");
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}
void run()
{
	std::atomic<bool> cancelled{false};
	Store			  store({}, catalog());
	auto			  bytes = header(2, 4096);
	chunkHeader(bytes, -1);
	bytes.push_back(1);
	u16(bytes, 4096);
	u32(bytes, 1);
	bytes.push_back(0);
	chunkHeader(bytes, 2, 1);
	auto in = input(bytes, 2, 4096, store.catalog());
	auto decoded = decodeBinary(in, cancelled);
	check(decoded->chunks.size() == 2 && decoded->chunks[0].count == 4096, "uniform decode failed");
	check(decoded->mBlockEntityCellsComplete && decoded->chunks[0].mBlockEntityCells.empty(),
		  "ordinary terrain must have a complete empty attachment list");
	auto legacy_catalog = catalog();
	legacy_catalog->mBlockEntityStates.clear();
	const auto legacy_decoded = decodeBinary(input(bytes, 2, 4096, legacy_catalog), cancelled);
	check(!legacy_decoded->mBlockEntityCellsComplete, "legacy catalog was mistaken for an empty attachment list");
	check(store.applyPrepared(0, decoded->prepared), "prepared decode did not publish");
	check(store.state({-1, 15, 47}) == 1 && store.state({-1, 15, 48}) == 0 && store.known({2, 0, 1}),
		  "decoded chunk addressing or known-empty semantics changed");
	check(!store.applyPrepared(0, decoded->prepared), "stale prepared revision accepted");
	store.reset({}, catalog());
	check(!store.applyPrepared(0, decoded->prepared), "old decode crossed world reset");
	for (unsigned bits = 1; bits <= 12; ++bits)
	{
		const unsigned		  paletteSize = 1u << bits;
		std::vector<uint32_t> palette(paletteSize);
		for (unsigned i = 0; i < paletteSize; ++i)
			palette[i] = i;
		std::vector<unsigned> indices(4096);
		unsigned			  count = 0;
		for (unsigned i = 0; i < 4096; ++i)
		{
			indices[i] = i % paletteSize;
			count += indices[i] != 0;
		}
		bytes = header(1, count);
		chunkHeader(bytes, -1);
		packed(bytes, bits, palette, indices);
		bytes.push_back(0);
		in = input(bytes, 1, count, store.catalog());
		in.epoch = store.epoch();
		decoded = decodeBinary(in, cancelled);
		check(store.applyPrepared(store.revision(), decoded->prepared), "packed decode publish failed");
		for (unsigned i = 0; i < 4096; ++i)
			check(store.state(store.config().cellAt({-1, 0, 1}, i)) == indices[i], "packed word crossing corrupted cell");
	}
	const auto before = store.revision();
	for (size_t length = 0; length < in.payload.size(); length += 79)
	{
		auto truncated = in;
		truncated.payload.resize(length);
		truncated.metadata.rawBytes = uint32_t(length);
		rejects([&]
				{ decodeBinary(truncated, cancelled); }, "truncated payload accepted");
	}
	auto invalid = in;
	invalid.payload.push_back(0);
	++invalid.metadata.rawBytes;
	rejects([&]
			{ decodeBinary(invalid, cancelled); }, "trailing payload accepted");
	invalid = in;
	invalid.payload[4] = 2;
	rejects([&]
			{ decodeBinary(invalid, cancelled); }, "wrong binary version accepted");
	invalid = in;
	invalid.payload[5] = 8;
	rejects([&]
			{ decodeBinary(invalid, cancelled); }, "wrong transport geometry accepted");
	invalid = in;
	++invalid.metadata.cells;
	rejects([&]
			{ decodeBinary(invalid, cancelled); }, "wrong declared count accepted");
	check(store.revision() == before, "failed decode touched live world");

	// Python lzma.FORMAT_ALONE fixture, explicit uncompressed size in header.
	auto compressed = unhex("5d000080001d00000000000000002690c44cd50461bdf91af54e1330f7b0ea864093b9fffff86c6000");
	auto lzma = input(compressed, 1, 0, store.catalog());
	lzma.metadata.compression = 1;
	lzma.metadata.rawBytes = 29;
	decoded = decodeBinary(lzma, cancelled);
	check(decoded->chunks[0].coord == Coord{-1, 0, 1} && decoded->chunks[0].count == 0, "LZMA-alone decode");
	Bytes valve{'L', 'Z', 'M', 'A'};
	u32(valve, 29);
	u32(valve, unsigned(compressed.size() - 13));
	valve.insert(valve.end(), compressed.begin(), compressed.begin() + 5);
	valve.insert(valve.end(), compressed.begin() + 13, compressed.end());
	lzma.payload = valve;
	check(decodeBinary(lzma, cancelled)->chunks[0].count == 0, "Valve LZMA decode");
	lzma.payload[8] ^= 1;
	rejects([&]
			{ decodeBinary(lzma, cancelled); }, "invalid LZMA compressed length accepted");
	cancelled = true;
	check(!decodeBinary(in, cancelled), "cancelled decoder produced a replacement");
	cancelled = false;
	// A no-NBT snapshot still needs defaults for attachment-capable states.
	// Detect them during the real binary decode, without relying on wire records.
	auto no_nbt_bytes = header(1, 2);
	chunkHeader(no_nbt_bytes, 0);
	std::vector<unsigned> no_nbt_indices(4096);
	no_nbt_indices[5] = 1;
	no_nbt_indices[65] = 2;
	packed(no_nbt_bytes, 2, {0, 1, 3}, no_nbt_indices);
	no_nbt_bytes.push_back(0);
	const auto no_nbt = decodeBinary(input(no_nbt_bytes, 1, 2, store.catalog()), cancelled);
	check(no_nbt->mBlockEntityCellsComplete && no_nbt->chunks[0].mBlockEntityCells.size() == 1
			  && no_nbt->chunks[0].mBlockEntityCells[0].index == 65 && no_nbt->chunks[0].mBlockEntityCells[0].state == 3,
		  "no-NBT snapshot lost its default attachment candidate or exported ordinary terrain");

	bytes = header(1, 1);
	chunkHeader(bytes, 0, 0, 1);
	std::vector<unsigned> indices(4096);
	indices[65] = 1;
	packed(bytes, 1, {0, 3}, indices);
	bytes.push_back(0);
	const std::string type = "minecraft:shulker_box", payload = "{\"hasData\":true,\"data\":{\"progress\":0}}";
	u16(bytes, 65);
	u16(bytes, unsigned(type.size()));
	bytes.insert(bytes.end(), type.begin(), type.end());
	u16(bytes, 1);
	u16(bytes, unsigned(payload.size()));
	bytes.insert(bytes.end(), payload.begin(), payload.end());
	Session session({}, catalog());
	in = input(bytes, 1, 1, session.store().catalog());
	const auto id = session.startDecode(in.metadata, in.payload);
	const auto limit = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (session.pollDecode(id).state != DecodeState::Ready)
	{
		const auto status = session.pollDecode(id);
		check(status.state != DecodeState::Failed, status.error.c_str());
		check(std::chrono::steady_clock::now() < limit, "session decode timeout");
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
	decoded = session.pollDecode(id).result;
	check(decoded->chunks[0].contextCells.size() == 1 && decoded->chunks[0].blockEntitiesJSON.find("\"revision\":13") != std::string::npos, "entity/context decode");
	rejects([&]
			{ session.commitDecode(0, id, {0}, {}); }, "unresolved live context accepted");
	Mutation overlay;
	overlay.chunk = {0, 0, 1};
	overlay.contexts = {{65, false, {0, 0, 1, 0, 0, 1}}};
	check(session.commitDecode(0, id, {0}, {overlay}), "typed context commit failed");
	check(session.store().snapshot()->profile({1, 4, 32}).opacity == 0, "typed context was lost at publication");
	rejects([&]
			{ session.pollDecode(id); }, "committed decoder job leaked");

	DecodeWorker worker;
	auto		 job = worker.submit(in);
	check(ready(worker, job).state == DecodeState::Ready, "decode worker failed");
	worker.release(job);
	job = worker.submit(in);
	worker.cancelAll();
	rejects([&]
			{ worker.poll(job); }, "cancelAll retained job handles");
	worker.stop();
	job = worker.submit(in);
	check(ready(worker, job).state == DecodeState::Ready, "decode worker failed to restart");
	worker.release(job);
	std::vector<uint64_t> jobs;
	for (unsigned i = 0; i < 32; ++i)
		jobs.push_back(worker.submit(in));
	rejects([&]
			{ worker.submit(in); }, "decode worker ignored queue capacity");
	worker.cancelAll();
}
} // namespace
int main()
{
	try
	{
		run();
		std::cout << "World decode: MCB9, packed widths, LZMA, typed contexts, publication and cancellation passed\n";
		return 0;
	}
	catch (const std::exception &e)
	{
		std::cerr << e.what() << '\n';
		return 1;
	}
}
