#pragma once
#include <algorithm>
#include <cstdint>
#include <vector>

namespace mcmesh::atlas {
struct UploadRegion { int x, y, width, height; };
inline UploadRegion Union(const UploadRegion& a, const UploadRegion& b) {
    const int x=std::min(a.x,b.x), y=std::min(a.y,b.y);
    return {x,y,std::max(a.x+a.width,b.x+b.width)-x,std::max(a.y+a.height,b.y+b.height)-y};
}
// Keep all changed pixels; the union's unchanged pixels come from atlas backing.
// A bounded amount of extra copying is cheaper than another Source Download.
inline void MergeUploadRegions(std::vector<UploadRegion>& regions) {
    constexpr int64_t overheadPixels=65536;
    for (size_t i=0;i<regions.size();++i) {
        for (size_t j=i+1;j<regions.size();) {
            const auto joined=Union(regions[i],regions[j]);
            const int64_t extra=int64_t(joined.width)*joined.height
                -int64_t(regions[i].width)*regions[i].height-int64_t(regions[j].width)*regions[j].height;
            if (extra<=overheadPixels) { regions[i]=joined; regions.erase(regions.begin()+j); }
            else ++j;
        }
    }
}
}
