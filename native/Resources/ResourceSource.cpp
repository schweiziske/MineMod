#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
#include "Resources/ResourceSource.h"
#include "miniz/miniz.h"
#include <algorithm>
#include <fstream>
#include <set>
#include <stdexcept>

namespace mcmesh::resources
{
namespace fs = std::filesystem;
namespace
{
[[noreturn]] void Fail(const std::string &code, const std::string &path = "")
{
	throw std::runtime_error(code + (path.empty() ? "" : ": " + path));
}
std::string Lower(std::string value)
{
	for (char &c : value)
		if (c >= 'A' && c <= 'Z')
			c = char(c - 'A' + 'a');
	return value;
}
void Regular(const fs::path &path, bool directory)
{
	const DWORD attributes = GetFileAttributesW(path.c_str());
	if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) || bool(attributes & FILE_ATTRIBUTE_DIRECTORY) != directory)
		Fail("resource_source_file_type", path.u8string());
}
std::string ReadFile(const fs::path &path, uint64_t budget)
{
	Regular(path, false);
	const uint64_t size = fs::file_size(path);
	if (size > budget)
		Fail("resource_source_entry_budget", path.u8string());
	std::ifstream input(path, std::ios::binary);
	if (!input)
		Fail("resource_source_open_failed", path.u8string());
	std::string bytes(size, '\0');
	if (size && !input.read(bytes.data(), std::streamsize(size)))
		Fail("resource_source_short_read", path.u8string());
	if (input.peek() != std::char_traits<char>::eof())
		Fail("resource_source_changed", path.u8string());
	return bytes;
}
void Insert(std::map<std::string, Entry> &entries, std::set<std::string> &names, const std::string &path,
			uint64_t size, uint32_t index, uint64_t &total, const Limits &limits)
{
	if (!SafePath(path))
		Fail("resource_source_unsafe_path", path);
	if (!names.insert(Lower(path)).second)
		Fail("resource_source_duplicate_path", path);
	if (entries.size() >= limits.entries || size > limits.entryBytes || size > limits.unpackedBytes - total)
		Fail("resource_source_budget", path);
	total += size;
	entries.emplace(path, Entry{size, index});
}
std::map<std::string, Entry> IndexDirectory(const fs::path &root, const Limits &limits)
{
	Regular(root, true);
	std::map<std::string, Entry> entries;
	std::set<std::string>		 names;
	uint64_t					 total = 0;
	uint32_t					 visited = 0;
	for (const auto &item : fs::recursive_directory_iterator(root))
	{
		if (++visited > limits.entries)
			Fail("resource_source_entry_count");
		const std::string relative = item.path().lexically_relative(root).generic_u8string();
		const bool		  directory = item.is_directory();
		Regular(item.path(), directory);
		if (!SafePath(relative))
			Fail("resource_source_unsafe_path", relative);
		if (directory)
		{
			if (!names.insert(Lower(relative)).second)
				Fail("resource_source_duplicate_path", relative);
		}
		else
			Insert(entries, names, relative, item.file_size(), 0, total, limits);
	}
	return entries;
}
std::string IndexRevision(const fs::path &root, const std::map<std::string, Entry> &entries)
{
	std::string text;
	for (const auto &pair : entries)
	{
		text += pair.first + "\n" + std::to_string(pair.second.size) + "\n";
		// A directory revision is content identity, including files not yet
		// consumed. Restored mtimes cannot reuse compatibility confirmations.
		text += Sha256(ReadFile(root / fs::u8path(pair.first), pair.second.size)) + "\n";
	}
	return Sha256(text);
}
} // namespace

bool SafePath(const std::string &path, bool directory)
{
	if (path.empty() || path.size() > 512 || path[0] == '/' || path.find('\\') != std::string::npos || path.find(':') != std::string::npos || path.find('\0') != std::string::npos)
		return false;
	size_t start = 0;
	while (start < path.size())
	{
		size_t end = path.find('/', start);
		if (end == std::string::npos)
			end = path.size();
		const std::string part = path.substr(start, end - start);
		if (part.empty() || part == "." || part == ".." || part.back() == '.' || part.back() == ' ')
			return false;
		for (unsigned char c : part)
			if (c < 32 || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*')
				return false;
		std::string base = Lower(part.substr(0, part.find('.')));
		if (base == "con" || base == "prn" || base == "aux" || base == "nul" ||
			(base.size() == 4 && (base.substr(0, 3) == "com" || base.substr(0, 3) == "lpt") && base[3] >= '1' && base[3] <= '9'))
			return false;
		if (end + 1 == path.size())
			return directory;
		start = end + 1;
	}
	return true;
}

std::string Sha256(std::string_view bytes)
{
	struct Provider
	{
		BCRYPT_ALG_HANDLE handle = nullptr;
		Provider()
		{
			if (BCryptOpenAlgorithmProvider(&handle, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
				Fail("resource_hash_provider");
		}
		~Provider() { BCryptCloseAlgorithmProvider(handle, 0); }
	};
	// BCryptHash owns per-call state; the algorithm provider is immutable and
	// reusable across source readers. Do not copy large Lua strings to hash them.
	static const Provider provider;
	uint8_t				  digest[32]{};
	const NTSTATUS		  status = BCryptHash(provider.handle, nullptr, 0,
											  reinterpret_cast<PUCHAR>(const_cast<char *>(bytes.data())), ULONG(bytes.size()), digest, sizeof(digest));
	if (status < 0)
		Fail("resource_hash_failed");
	std::string result;
	result.reserve(64);
	for (uint8_t value : digest)
	{
		result.push_back("0123456789abcdef"[value >> 4]);
		result.push_back("0123456789abcdef"[value & 15]);
	}
	return result;
}
struct Source::Impl
{
	fs::path						   locator;
	Limits							   limits;
	std::map<std::string, Entry>	   entries;
	std::map<std::string, std::string> consumed;
	std::string						   root, revision, archiveBytes;
	mz_zip_archive					   archive{};
	bool							   zip = false;
	~Impl()
	{
		if (zip)
			mz_zip_reader_end(&archive);
	}
};
Source::Source() : impl(std::make_unique<Impl>()) {}
Source::~Source() = default;
std::unique_ptr<Source> Source::Open(const fs::path &locator, const Limits &limits)
{
	auto  source = std::unique_ptr<Source>(new Source);
	auto &state = *source->impl;
	state.locator = locator;
	state.limits = limits;
	if (fs::is_directory(locator))
	{
		state.entries = IndexDirectory(locator, limits);
		state.revision = IndexRevision(locator, state.entries);
	}
	else
	{
		if (Lower(locator.extension().u8string()) != ".zip")
			Fail("resource_source_expected_zip_or_directory");
		state.archiveBytes = ReadFile(locator, limits.compressedBytes);
		state.revision = Sha256(state.archiveBytes);
		if (!mz_zip_reader_init_mem(&state.archive, state.archiveBytes.data(), state.archiveBytes.size(), MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY))
			Fail("resource_source_zip_invalid");
		state.zip = true;
		const mz_uint count = mz_zip_reader_get_num_files(&state.archive);
		if (count > limits.entries)
			Fail("resource_source_entry_count");
		uint64_t			  total = 0;
		std::set<std::string> names;
		for (mz_uint index = 0; index < count; ++index)
		{
			mz_zip_archive_file_stat stat{};
			if (!mz_zip_reader_file_stat(&state.archive, index, &stat))
				Fail("resource_source_zip_entry_invalid");
			const mz_uint length = mz_zip_reader_get_filename(&state.archive, index, nullptr, 0);
			if (length < 2 || length > 513)
				Fail("resource_source_zip_path_length");
			std::string path(length, '\0');
			if (mz_zip_reader_get_filename(&state.archive, index, path.data(), length) != length)
				Fail("resource_source_zip_path_read");
			path.pop_back();
			if (!SafePath(path, stat.m_is_directory != 0))
				Fail("resource_source_unsafe_path", path);
			if (stat.m_is_encrypted || !mz_zip_reader_is_file_supported(&state.archive, index))
				Fail("resource_source_zip_method", path);
			if (((stat.m_external_attr >> 16) & 0170000) == 0120000)
				Fail("resource_source_symlink", path);
			if (stat.m_is_directory)
			{
				if (path.back() == '/')
					path.pop_back();
				if (!names.insert(Lower(path)).second)
					Fail("resource_source_duplicate_path", path);
				continue;
			}
			Insert(state.entries, names, path, stat.m_uncomp_size, index, total, limits);
		}
		std::set<std::string> files;
		for (const auto &entry : state.entries)
			files.insert(Lower(entry.first));
		for (const auto &entry : state.entries)
		{
			size_t slash = entry.first.find('/');
			while (slash != std::string::npos)
			{
				if (files.count(Lower(entry.first.substr(0, slash))))
					Fail("resource_source_file_directory_collision", entry.first);
				slash = entry.first.find('/', slash + 1);
			}
		}
	}
	if (state.entries.count("pack.mcmeta"))
		state.root = "";
	else
	{
		std::vector<std::string> candidates;
		for (const auto &entry : state.entries)
		{
			const size_t slash = entry.first.find('/');
			if (slash != std::string::npos && entry.first.substr(slash + 1) == "pack.mcmeta")
				candidates.push_back(entry.first.substr(0, slash + 1));
		}
		if (candidates.size() != 1)
			Fail(candidates.empty() ? "resource_source_pack_mcmeta_missing" : "resource_source_ambiguous_root");
		state.root = candidates.front();
	}
	return source;
}
const std::map<std::string, Entry> &Source::Entries() const
{
	return impl->entries;
}
const std::string &Source::Root() const
{
	return impl->root;
}
const std::string &Source::Revision() const
{
	return impl->revision;
}
bool Source::Has(const std::string &path) const
{
	return impl->entries.count(impl->root + path) != 0;
}
const std::string &Source::Read(const std::string &relative)
{
	auto			 &state = *impl;
	const std::string path = state.root + relative;
	const auto		  existing = state.consumed.find(path);
	if (existing != state.consumed.end())
		return existing->second;
	const auto entry = state.entries.find(path);
	if (entry == state.entries.end())
		Fail("resource_source_missing", relative);
	std::string bytes;
	if (state.zip)
	{
		bytes.resize(size_t(entry->second.size));
		if (!mz_zip_reader_extract_to_mem(&state.archive, entry->second.index, bytes.data(), bytes.size(), 0))
			Fail("resource_source_zip_decode_or_crc", relative);
	}
	else
	{
		bytes = ReadFile(state.locator / fs::u8path(path), state.limits.entryBytes);
		if (bytes.size() != entry->second.size)
			Fail("resource_source_changed", relative);
	}
	return state.consumed.emplace(path, std::move(bytes)).first->second;
}
bool Source::Unchanged() const
{
	const auto &state = *impl;
	if (state.zip)
		return Sha256(ReadFile(state.locator, state.limits.compressedBytes)) == state.revision;
	const auto entries = IndexDirectory(state.locator, state.limits);
	if (IndexRevision(state.locator, entries) != state.revision)
		return false;
	for (const auto &item : state.consumed)
		if (ReadFile(state.locator / fs::u8path(item.first), state.limits.entryBytes) != item.second)
			return false;
	return true;
}
} // namespace mcmesh::resources
