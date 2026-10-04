#include "../atlas_pixels.h"
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <iostream>

int main() {
    std::string line;
    while (std::getline(std::cin, line)) {
        rapidjson::Document doc;
        doc.Parse(line.c_str());
        if (doc.HasParseError() || !doc.IsObject() || !doc.HasMember("pixels")) return 2;
        mcmesh::atlas::Image image{doc["width"].GetInt(), doc["height"].GetInt(), {}};
        for (auto& value : doc["pixels"].GetArray()) {
            const uint32_t p = value.GetUint();
            image.pixels.push_back({uint8_t(p >> 16), uint8_t(p >> 8), uint8_t(p), uint8_t(p >> 24)});
        }
        std::vector<mcmesh::atlas::Image> levels;
        std::string error;
        const bool ok = mcmesh::atlas::GenerateMips(std::move(image), doc["mip"].GetInt(),
            mcmesh::atlas::MipStrategy(doc["strategy"].GetInt()), doc["bias"].GetFloat(), doc["item"].GetBool(), levels, error);
        rapidjson::StringBuffer buffer;
        rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
        writer.StartObject(); writer.Key("ok"); writer.Bool(ok);
        writer.Key("levels"); writer.StartArray();
        for (const auto& level : levels) {
            writer.StartArray(); writer.Int(level.width); writer.Int(level.height); writer.StartArray();
            for (const auto p : level.pixels) writer.Uint((uint32_t(p.a) << 24) | (uint32_t(p.r) << 16) | (uint32_t(p.g) << 8) | p.b);
            writer.EndArray(); writer.EndArray();
        }
        writer.EndArray(); writer.EndObject(); std::cout << buffer.GetString() << '\n';
    }
}
