#pragma once
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace mcmesh::resources
{
struct Limits
{
	uint64_t compressedBytes = 512ull * 1024 * 1024;
	uint64_t unpackedBytes = 1024ull * 1024 * 1024;
	uint64_t entryBytes = 128ull * 1024 * 1024;
	uint32_t entries = 65536;
};
struct Entry
{
	uint64_t size = 0;
	uint32_t index = 0;
};
// CPU-only source. Archive extraction is in memory; pack paths never become
// executable code or destination filenames. Open takes an already authorized
// locator (the Lua adapter must resolve it beneath the resourcepack roots).
class Source
{
public:
	static std::unique_ptr<Source> Open(const std::filesystem::path &locator, const Limits &limits = {});
	~Source();
	const std::map<std::string, Entry> &Entries() const;
	const std::string				   &Root() const;
	const std::string				   &Revision() const;
	bool								Has(const std::string &path) const;
	const std::string				   &Read(const std::string &path);
	// Recheck directory index and every consumed file before publishing a build.
	bool Unchanged() const;

private:
	struct Impl;
	Source();
	std::unique_ptr<Impl> impl;
};
bool		SafePath(const std::string &path, bool directory = false);
std::string Sha256(std::string_view bytes);
} // namespace mcmesh::resources
