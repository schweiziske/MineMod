#include "World/WorldDecoder.h"
#include "Core/CpuWorkGate.h"
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include "utils/lzma/C/LzmaDec.h"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <unordered_set>

namespace mcmesh::world
{
namespace
{
using Clock = std::chrono::steady_clock;
constexpr size_t   MaxRaw = 64 * 1024 * 1024, MaxPayload = 16 * 1024 * 1024;
constexpr size_t   MaxReserved = 256 * 1024 * 1024, MaxJobs = 32;
constexpr unsigned SectionCells = 4096;
void			   require(bool condition, const char *error)
{
	if (!condition)
		throw std::runtime_error(error);
}
uint32_t le32(const uint8_t *p)
{
	return p[0] | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
struct Reader
{
	const uint8_t *data;
	size_t		   size, pos = 0;
	const uint8_t *bytes(size_t count)
	{
		require(count <= size - pos, "truncated_binary_patch");
		const auto *result = data + pos;
		pos += count;
		return result;
	}
	uint8_t	 u8() { return bytes(1)[0]; }
	uint16_t u16()
	{
		const auto *p = bytes(2);
		return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
	}
	uint32_t u32() { return le32(bytes(4)); }
	int		 i32()
	{
		const uint32_t raw = u32();
		int32_t		   result;
		std::memcpy(&result, &raw, 4);
		return result;
	}
};
void *allocate(ISzAllocPtr, size_t bytes)
{
	return std::malloc(bytes);
}
void freeBytes(ISzAllocPtr, void *ptr)
{
	std::free(ptr);
}
ISzAlloc			 allocator{allocate, freeBytes};
std::vector<uint8_t> decompress(const DecodeInput &input)
{
	const auto &bytes = input.payload;
	require(bytes.size() >= 13, "invalid_lzma_header");
	const bool	 valve = bytes.size() >= 17 && std::memcmp(bytes.data(), "LZMA", 4) == 0;
	const size_t header = valve ? 17 : 13;
	const auto	*properties = bytes.data() + (valve ? 12 : 0);
	uint64_t	 rawSize = valve ? le32(bytes.data() + 4) : 0;
	if (!valve)
		for (unsigned i = 0; i < 8; ++i)
			rawSize |= uint64_t(bytes[5 + i]) << (i * 8);
	const size_t compressed = valve ? le32(bytes.data() + 8) : bytes.size() - header;
	require(rawSize == input.metadata.rawBytes && rawSize > 0 && rawSize <= MaxRaw && le32(properties + 1) <= MaxRaw, "invalid_lzma_output_size");
	require(compressed == bytes.size() - header, "invalid_lzma_input_size");
	std::vector<uint8_t> result(size_t(rawSize), uint8_t(0));
	SizeT				 outSize = result.size(), inSize = compressed;
	ELzmaStatus			 status = LZMA_STATUS_NOT_SPECIFIED;
	const SRes			 code = LzmaDecode(result.data(), &outSize, bytes.data() + header, &inSize,
										   properties, LZMA_PROPS_SIZE, LZMA_FINISH_END, &status, &allocator);
	require(code == SZ_OK && outSize == result.size() && inSize == compressed && (status == LZMA_STATUS_FINISHED_WITH_MARK || status == LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK),
			"lzma_decode_failed");
	return result;
}
unsigned section(Reader &reader, uint32_t *states, size_t stateCount)
{
	const auto mode = reader.u8();
	if (mode == 0)
		return 0;
	const auto count = reader.u16();
	require(count > 0 && count <= SectionCells, "invalid_section_count");
	if (mode == 1)
	{
		const auto state = reader.u32();
		require(count == SectionCells && state > 0 && state < stateCount, "invalid_uniform_section");
		std::fill_n(states, SectionCells, state);
		return count;
	}
	require(mode == 2, "invalid_section_mode");
	const auto bits = reader.u8();
	const auto paletteSize = reader.u16();
	require(bits >= 1 && bits <= 12 && paletteSize >= 2 && paletteSize <= SectionCells && paletteSize <= (1u << bits), "invalid_packed_section");
	std::vector<uint32_t> palette;
	palette.reserve(paletteSize);
	std::unordered_set<uint32_t> seen;
	for (unsigned i = 0; i < paletteSize; ++i)
	{
		const auto state = reader.u32();
		require(state < stateCount && seen.insert(state).second, "invalid_section_palette");
		palette.push_back(state);
	}
	const auto wordCount = reader.u16();
	require(wordCount == (SectionCells * bits + 31u) / 32u, "invalid_section_word_count");
	const auto	  *words = reader.bytes(size_t(wordCount) * 4);
	const uint64_t mask = (uint64_t(1) << bits) - 1;
	unsigned	   actual = 0;
	for (unsigned i = 0; i < SectionCells; ++i)
	{
		const unsigned bit = i * bits, word = bit / 32, shift = bit % 32;
		uint64_t	   value = le32(words + word * 4);
		if (shift + bits > 32)
			value |= uint64_t(le32(words + (word + 1) * 4)) << 32;
		const auto index = unsigned((value >> shift) & mask);
		require(index < paletteSize, "section_palette_index_out_of_range");
		states[i] = palette[index];
		actual += states[i] != 0;
	}
	require(actual == count, "section_count_mismatch");
	return count;
}
std::string entities(Reader &reader, unsigned count, const std::vector<uint32_t> &states, uint32_t revision)
{
	if (!count)
		return {};
	rapidjson::StringBuffer					   buffer;
	rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
	std::unordered_set<unsigned>			   seen;
	writer.StartArray();
	for (unsigned i = 0; i < count; ++i)
	{
		const auto li = reader.u16(), typeLength = reader.u16();
		require(li < states.size() && states[li] != 0 && seen.insert(li).second,
				"invalid_block_entity_cell");
		require(typeLength > 0 && typeLength <= 160, "invalid_block_entity_type");
		const auto *type = reader.bytes(typeLength);
		require(std::memchr(type, 0, typeLength) == nullptr, "invalid_block_entity_type");
		const auto codec = reader.u16(), length = reader.u16();
		require(length > 0 && length <= 32768, "invalid_block_entity_length");
		const auto		   *data = reader.bytes(length);
		rapidjson::Document payload;
		payload.Parse<rapidjson::kParseValidateEncodingFlag>(reinterpret_cast<const char *>(data), length);
		require(!payload.HasParseError() && payload.IsObject(), "invalid_block_entity_payload");
		const auto hasData = payload.FindMember("hasData");
		require(hasData != payload.MemberEnd() && hasData->value.IsBool(), "invalid_block_entity_payload");
		const auto value = payload.FindMember("data");
		require(!hasData->value.GetBool() || value != payload.MemberEnd(), "missing_block_entity_data");
		writer.StartObject();
		writer.Key("localIndex");
		writer.Uint(li);
		writer.Key("type");
		writer.String(reinterpret_cast<const char *>(type), typeLength);
		writer.Key("codecVersion");
		writer.Uint(codec);
		if (hasData->value.GetBool())
		{
			writer.Key("data");
			value->value.Accept(writer);
		}
		writer.Key("revision");
		writer.Uint(revision);
		writer.EndObject();
	}
	writer.EndArray();
	return {buffer.GetString(), buffer.GetSize()};
}
} // namespace
void DecodeInput::validate() const
{
	config.validate();
	require(catalog && !catalog->states.empty() && epoch != 0, "binary_decode_requires_world_catalog");
	require(config.chunkSize == 16 && config.chunkHeight == 32, "binary_transport_requires_16x16x32");
	require(metadata.compression <= 1 && metadata.rawBytes >= 14 && metadata.rawBytes <= MaxRaw,
			"invalid_binary_decode_metadata");
	require(metadata.chunks > 0 && metadata.chunks <= 64 && metadata.cells <= 131072 && metadata.cells <= metadata.chunks * config.cellCount(), "invalid_binary_decode_counts");
	require(!payload.empty() && payload.size() <= MaxPayload, "binary_payload_exceeds_budget");
	require(metadata.compression != 0 || payload.size() == metadata.rawBytes, "binary_raw_size_mismatch");
}
std::shared_ptr<const DecodedResult> decodeBinary(const DecodeInput &input, const std::atomic<bool> &cancelled)
{
	input.validate();
	if (cancelled.load())
		return nullptr;
	const auto			 started = Clock::now();
	std::vector<uint8_t> expanded;
	if (input.metadata.compression == 1)
		expanded = decompress(input);
	if (cancelled.load())
		return nullptr;
	const auto &raw = input.metadata.compression ? expanded : input.payload;
	const auto	parsed = Clock::now();
	Reader		reader{raw.data(), raw.size()};
	require(std::memcmp(reader.bytes(4), "MCB9", 4) == 0, "binary_patch_magic_mismatch");
	require(reader.u8() == 1, "binary_patch_version_mismatch");
	const auto cs = reader.u8(), ch = reader.u8(), sections = reader.u8();
	require(cs == 16 && ch == 32 && sections == 2, "binary_patch_geometry_mismatch");
	const auto count = reader.u16();
	const auto total = reader.u32();
	require(count == input.metadata.chunks && total == input.metadata.cells, "binary_patch_metadata_mismatch");
	auto output = std::make_shared<DecodedResult>();
	output->metadata = input.metadata;
	output->mBlockEntityCellsComplete = !input.catalog->mBlockEntityStates.empty();
	std::vector<Mutation> mutations;
	mutations.reserve(count);
	output->chunks.reserve(count);
	Grid<bool> seen;
	unsigned   actual = 0;
	for (unsigned i = 0; i < count; ++i)
	{
		if (cancelled.load())
			return nullptr;
		const Coord coord{reader.i32(), reader.i32(), reader.i32()};
		input.config.validateChunk(coord);
		require(seen.emplace(coord, true).second, "duplicate_binary_chunk");
		const auto flags = reader.u8();
		const auto entityCount = reader.u16();
		require(flags <= 1 && entityCount <= input.config.cellCount(), "invalid_binary_chunk_header");
		require(flags != 1 || entityCount == 0, "tombstone_block_entities");
		Mutation mutation;
		mutation.kind = Mutation::Kind::Replace;
		mutation.chunk = coord;
		DecodedChunk chunk;
		chunk.coord = coord;
		std::vector<uint32_t> states(input.config.cellCount());
		if (flags == 0)
		{
			for (unsigned s = 0; s < 2; ++s)
				chunk.count += section(reader, states.data() + s * SectionCells, input.catalog->states.size());
			chunk.blockEntitiesJSON = entities(reader, entityCount, states, input.metadata.revision);
		}
		mutation.terrainPresent = chunk.count > 0;
		mutation.cells.reserve(chunk.count);
		for (unsigned li = 0; li < states.size(); ++li)
		{
			const auto state = states[li];
			if (!state)
				continue;
			mutation.cells.push_back({li, state});
			if (!input.catalog->contextual.empty() && input.catalog->contextual[state])
				chunk.contextCells.push_back({li, state});
			if (output->mBlockEntityCellsComplete && input.catalog->mBlockEntityStates[state])
				chunk.mBlockEntityCells.push_back({li, state});
		}
		actual += chunk.count;
		require(actual <= total, "binary_patch_total_count_mismatch");
		mutations.push_back(std::move(mutation));
		output->chunks.push_back(std::move(chunk));
	}
	require(actual == total && reader.pos == reader.size, "binary_patch_count_or_trailing_data");
	if (cancelled.load())
		return nullptr;
	output->prepared = prepareReplacements(input.config, input.catalog, input.epoch, mutations);
	if (cancelled.load())
		return nullptr;
	output->decompressMS = std::chrono::duration<double, std::milli>(parsed - started).count();
	output->parseMS = std::chrono::duration<double, std::milli>(Clock::now() - parsed).count();
	return output;
}
struct DecodeWorker::Impl
{
	std::shared_ptr<core::CpuWorkGate> mCpuWorkGate = core::GetCpuWorkGate();
	struct Job
	{
		uint64_t		  id = 0;
		size_t			  reservation = 0;
		DecodeInput		  input;
		DecodeStatus	  status;
		std::atomic<bool> cancelled{false};
	};
	mutable std::mutex								   mutex;
	std::condition_variable							   wake;
	std::deque<std::shared_ptr<Job>>				   queue;
	std::unordered_map<uint64_t, std::shared_ptr<Job>> jobs;
	std::thread										   thread;
	bool											   stopping = false;
	uint64_t										   next = 1;
	size_t											   reserved = 0;
	void											   run()
	{
		for (;;)
		{
			std::shared_ptr<Job> job;
			{
				std::unique_lock<std::mutex> lock(mutex);
				wake.wait(lock, [&]
						  { return stopping || !queue.empty(); });
				if (stopping)
					return;
				job = queue.front();
				queue.pop_front();
				job->status.state = DecodeState::Running;
			}
			DecodeStatus result;
			core::CpuWorkPermit permit;
			try
			{
				permit = mCpuWorkGate->Acquire(core::ECpuWorkClass::Decode, job->cancelled);
				if (permit)
					result.result = decodeBinary(job->input, job->cancelled);
				result.state = result.result ? DecodeState::Ready : DecodeState::Cancelled;
			}
			catch (const std::exception &e)
			{
				result.state = DecodeState::Failed;
				result.error = e.what();
			}
			catch (...)
			{
				result.state = DecodeState::Failed;
				result.error = "unknown Native decode worker failure";
			}
			job->input = {};
			permit.Reset(); // Input disposal belongs to worker CPU work, not publication.
			{
				std::lock_guard<std::mutex> lock(mutex);
				if (job->cancelled.load())
				{
					result = {};
					result.state = DecodeState::Cancelled;
				}
				job->status = std::move(result);
				// Cancellation keeps the running job's reservation until it exits.
				if (jobs.find(job->id) == jobs.end())
					reserved -= job->reservation;
			}
		}
	}
};
DecodeWorker::DecodeWorker() : impl_(std::make_unique<Impl>()) {}
DecodeWorker::~DecodeWorker()
{
	stop();
}
uint64_t DecodeWorker::submit(DecodeInput input)
{
	input.validate();
	auto job = std::make_shared<Impl::Job>();
	// Admission budget covers compressed input, decompressed/JSON temporaries
	// and decoded/rearranged section arrays, not unrelated process allocations.
	job->reservation = input.payload.size() + size_t(input.metadata.rawBytes) * 3 + size_t(input.metadata.chunks) * input.config.cellCount() * sizeof(uint32_t) * 4;
	// Vector capacity can grow beyond the sparse count. Account for the new list
	// before admitting the job, even when every transmitted cell is an attachment.
	if (!input.catalog->mBlockEntityStates.empty())
		job->reservation += size_t(input.metadata.cells) * sizeof(CellEdit) * 2;
	// Decoder replacements have no per-cell contexts yet. Reserve their cached
	// section inventory, including vector growth and the new inventory object.
	const auto inventory_bytes = l2::checkedAdd(sizeof(l2::MemoryUsage),
		l2::checkedMultiply(size_t(input.config.sectionCount()) * 2, sizeof(l2::SharedAllocation)));
	job->reservation = l2::checkedAdd(job->reservation,
		l2::checkedMultiply(input.metadata.chunks, inventory_bytes));
	job->input = std::move(input);
	auto					   &impl = *impl_;
	std::lock_guard<std::mutex> lock(impl.mutex);
	require(impl.jobs.size() < MaxJobs && job->reservation <= MaxReserved - impl.reserved,
			"native_decode_queue_full");
	if (!impl.thread.joinable())
	{
		impl.stopping = false;
		impl.thread = std::thread([&impl]
								  { impl.run(); });
	}
	job->id = impl.next++;
	impl.jobs.emplace(job->id, job);
	try
	{
		impl.queue.push_back(job);
	}
	catch (...)
	{
		impl.jobs.erase(job->id);
		throw;
	}
	impl.reserved += job->reservation;
	impl.wake.notify_one();
	return job->id;
}
DecodeStatus DecodeWorker::poll(uint64_t id) const
{
	auto					   &impl = *impl_;
	std::lock_guard<std::mutex> lock(impl.mutex);
	const auto					found = impl.jobs.find(id);
	require(found != impl.jobs.end(), "unknown_native_decode_job");
	return found->second->status;
}
void DecodeWorker::release(uint64_t id)
{
	auto &impl = *impl_;
	{
		std::lock_guard<std::mutex> lock(impl.mutex);
		const auto found = impl.jobs.find(id);
		if (found == impl.jobs.end())
			return;
		const auto &job = found->second;
		job->cancelled = true;
		if (job->status.state != DecodeState::Running)
		{
			if (job->status.state == DecodeState::Queued)
				impl.queue.erase(std::remove(impl.queue.begin(), impl.queue.end(), job), impl.queue.end());
			impl.reserved -= job->reservation;
		}
		impl.jobs.erase(found);
	}
	impl.mCpuWorkGate->NotifyCancellation();
}
void DecodeWorker::cancelAll()
{
	auto &impl = *impl_;
	{
		std::lock_guard<std::mutex> lock(impl.mutex);
		for (auto &entry : impl.jobs)
		{
			entry.second->cancelled = true;
			if (entry.second->status.state != DecodeState::Running)
				impl.reserved -= entry.second->reservation;
		}
		impl.jobs.clear();
		impl.queue.clear();
	}
	impl.mCpuWorkGate->NotifyCancellation();
}
void DecodeWorker::stop()
{
	auto &impl = *impl_;
	{
		std::lock_guard<std::mutex> lock(impl.mutex);
		impl.stopping = true;
		for (auto &entry : impl.jobs)
			entry.second->cancelled = true;
		impl.wake.notify_all();
	}
	impl.mCpuWorkGate->NotifyCancellation();
	if (impl.thread.joinable())
		impl.thread.join();
	std::lock_guard<std::mutex> lock(impl.mutex);
	impl.jobs.clear();
	impl.queue.clear();
	impl.reserved = 0;
}
} // namespace mcmesh::world
