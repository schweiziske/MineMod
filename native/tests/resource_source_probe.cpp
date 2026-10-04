#include "../resource_source.h"
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <iostream>

int main(int argc,char** argv) {
    rapidjson::StringBuffer buffer; rapidjson::Writer<rapidjson::StringBuffer> out(buffer);
    out.StartObject();
    try {
        if(argc<2) throw std::runtime_error("expected path");
        mcmesh::resources::Limits limits;
        if(argc>3 && std::string(argv[3])!="wait") limits.entryBytes=std::stoull(argv[3]);
        const auto source=mcmesh::resources::Source::Open(std::filesystem::u8path(argv[1]),limits);
        out.Key("root"); out.String(source->Root().c_str()); out.Key("revision"); out.String(source->Revision().c_str());
        out.Key("entries"); out.Uint(unsigned(source->Entries().size()));
        const auto& metadata=source->Read("pack.mcmeta"); out.Key("metadata"); out.String(metadata.c_str());
        if(argc>2) {const auto& resource=source->Read(argv[2]);out.Key("resource");out.String(resource.c_str());}
        if(argc>3 && std::string(argv[3])=="wait") {std::cout<<"ready"<<std::endl;std::cin.get();}
        const bool unchanged=source->Unchanged();out.Key("unchanged");out.Bool(unchanged);
        out.Key("ok"); out.Bool(true);
    } catch(const std::exception& error) {
        out.Key("ok"); out.Bool(false); out.Key("error"); out.String(error.what());
    }
    out.EndObject(); std::cout<<buffer.GetString()<<'\n';
}
