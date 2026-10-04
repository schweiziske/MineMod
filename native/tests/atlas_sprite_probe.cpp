#include "../atlas_sprite.h"
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <fstream>
#include <iostream>
#include <iterator>
int main() {
    std::string line;
    while (std::getline(std::cin, line)) {
        rapidjson::Document d; d.Parse(line.c_str());
        if (d.HasParseError() || !d.IsObject()) return 2;
        std::ifstream file(d["path"].GetString(), std::ios::binary);
        std::string png((std::istreambuf_iterator<char>(file)), {}), error;
        mcmesh::atlas::Image image; mcmesh::atlas::Sprite sprite;
        bool ok = mcmesh::atlas::DecodePNG(png, image, error);
        if (ok && d.HasMember("compose")) {
            const auto& c=d["compose"];
            std::ifstream other(c["path"].GetString(),std::ios::binary);
            std::string bytes((std::istreambuf_iterator<char>(other)),{});
            mcmesh::atlas::Image overlay;
            ok=mcmesh::atlas::DecodePNG(bytes,overlay,error);
            if(ok) ok=mcmesh::atlas::ComposeSheets(image,c["bw"].GetInt(),c["bh"].GetInt(),&overlay,
                c["ow"].GetInt(),c["oh"].GetInt(),{128,255,64,255},error);
        }
        std::vector<mcmesh::atlas::Image> levels;
        if (ok && d.HasMember("frames")) {
            std::vector<int> frames;
            for (const auto& v : d["frames"].GetArray()) frames.push_back(v.GetInt());
            ok = mcmesh::atlas::CompileSprite(image, d["width"].GetInt(), d["height"].GetInt(), frames,
                d["mip"].GetInt(), d["padding"].GetInt(), d.HasMember("strategy")?mcmesh::atlas::MipStrategy(d["strategy"].GetInt()):mcmesh::atlas::MipStrategy::Mean, 0, false,
                d["budget"].GetUint64(), sprite, error);
            if (ok) ok = mcmesh::atlas::SampleSprite(sprite, d["a"].GetInt(), d["b"].GetInt(), d["fraction"].GetFloat(), levels, error);
        } else if (ok) levels.push_back(std::move(image));
        rapidjson::StringBuffer buffer; rapidjson::Writer<rapidjson::StringBuffer> w(buffer);
        w.StartObject(); w.Key("ok"); w.Bool(ok); w.Key("error"); w.String(error.c_str());
        w.Key("constant");w.Bool(sprite.constant);
        w.Key("bytes"); w.Uint64(sprite.bytes); w.Key("levels"); w.StartArray();
        for (const auto& level : levels) {
            w.StartObject(); w.Key("width"); w.Int(level.width); w.Key("height"); w.Int(level.height);
            w.Key("pixels"); w.StartArray();
            for (const auto p : level.pixels) { w.StartArray(); w.Int(p.r); w.Int(p.g); w.Int(p.b); w.Int(p.a); w.EndArray(); }
            w.EndArray(); w.EndObject();
        }
        w.EndArray(); w.EndObject(); std::cout << buffer.GetString() << '\n';
    }
}
