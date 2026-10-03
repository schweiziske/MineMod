#include "l2_fluid.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace mcmesh::l2 {
namespace {
constexpr double Epsilon = 0.0001;
constexpr int Off[6][3] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};
constexpr double Corners[6][4][3] = {
    {{0,0,1},{1,0,1},{1,1,1},{0,1,1}}, {{0,1,0},{1,1,0},{1,0,0},{0,0,0}},
    {{1,0,0},{1,1,0},{1,1,1},{1,0,1}}, {{0,1,0},{0,0,0},{0,0,1},{0,1,1}},
    {{1,1,0},{0,1,0},{0,1,1},{1,1,1}}, {{0,0,0},{1,0,0},{1,0,1},{0,0,1}}
};
bool covered(const FluidState& s, unsigned face, double height) {
    return height > 0 && (face != 0 || height >= 1 - Epsilon)
        && s.cover[face] > 0 && (face < 2 || height <= s.cover[face] + Epsilon);
}
double heightAt(const FluidSource& source, int x, int y, int z, uint8_t kind) {
    const auto& s = source.fluid(x,y,z);
    if (s.kind == kind) return source.fluid(x,y,z+1).kind == kind ? 1 : s.height;
    return s.solid ? -1 : 0;
}
double average(const FluidSource& source, double self, double a, double b, int x, int y, int z, uint8_t kind) {
    if (a >= 1 || b >= 1) return 1;
    double total = 0, weight = 0;
    const auto add = [&](double h) {
        if (h >= .8) { total += h * 10; weight += 10; }
        else if (h >= 0) { total += h; ++weight; }
    };
    if (a > 0 || b > 0) {
        const double diagonal = heightAt(source,x,y,z,kind);
        if (diagonal >= 1) return 1;
        add(diagonal);
    }
    add(self); add(a); add(b);
    return weight > 0 ? total / weight : 0;
}
double flowDistance(const FluidSource& source, int x, int y, int z, const FluidState& self) {
    const auto& n = source.fluid(x,y,z);
    if (n.kind == self.kind) return self.height - n.height;
    if (n.kind || n.blocksMotion) return 0;
    const auto& below = source.fluid(x,y,z-1);
    return below.kind == self.kind && below.height > 0 ? self.height - (below.height - 8.0/9.0) : 0;
}
}

void compileFluidCoverage(FluidState& state, bool full, bool empty, const std::vector<FluidBox>& boxes) {
    // Compile the union of boundary rectangles to a covered height once per
    // profile. Runtime face tests do not allocate or traverse collision boxes.
    require(boxes.size() <= 4096, "fluid collision box limit");
    for (const auto& box : boxes) {
        for (double v : box) require(std::isfinite(v) && std::abs(v) <= 32768, "invalid fluid collision box");
        for (unsigned a = 0; a < 3; ++a) require(box[a] <= box[a+3], "inverted fluid collision box");
    }
    state.cover.fill(0); state.sturdy = 0;
    for (unsigned face = 0; face < 6; ++face) {
        double height = full ? 1 : 0;
        if (!full) {
            std::vector<std::array<double,4>> rects;
            std::vector<double> edges{0,1};
            for (const auto& b : boxes) {
                const unsigned normal = face < 2 ? 2 : face < 4 ? 0 : 1;
                if (face % 2 == 0 ? b[normal] > Epsilon : b[normal+3] < 1-Epsilon) continue;
                const unsigned a = face < 2 || face >= 4 ? 0 : 1;
                const unsigned v = face < 2 ? 1 : 2;
                const std::array<double,4> r{std::max(0.0,b[a]),std::min(1.0,b[a+3]),
                    std::max(0.0,b[v]),std::min(1.0,b[v+3])};
                if (r[1] <= r[0]+Epsilon || r[3] <= r[2]+Epsilon) continue;
                rects.push_back(r); edges.push_back(r[0]); edges.push_back(r[1]);
            }
            std::sort(edges.begin(),edges.end());
            height = 1;
            double previous = 0;
            for (double edge : edges) {
                if (edge > previous + Epsilon) {
                    const double sample = (edge+previous)*.5;
                    double to = 0;
                    for (;;) {
                        double next = to;
                        for (const auto& r : rects)
                            if (r[0] <= sample+Epsilon && r[1] >= sample-Epsilon && r[2] <= to+Epsilon)
                                next = std::max(next,r[3]);
                        if (next <= to+Epsilon) break;
                        to = next;
                    }
                    height = std::min(height,to);
                }
                previous = std::max(previous,edge);
            }
        }
        if (height >= 1-Epsilon) state.sturdy |= uint8_t(1u << (face ^ 1));
        state.cover[face] = empty ? 0 : face < 2 ? (height >= 1-Epsilon ? 1 : 0) : height;
    }
    state.ready = true;
}

FluidGeometry fluidGeometry(const FluidRecipe& r, const FluidSource& source, const int p[3]) {
    const int x=p[0], y=p[1], z=p[2];
    const auto& self = source.fluid(x,y,z);
    double h[4];
    const double hs = heightAt(source,x,y,z,r.kind);
    if (hs >= 1) std::fill(std::begin(h),std::end(h),1);
    else {
        const double xn=heightAt(source,x-1,y,z,r.kind), xp=heightAt(source,x+1,y,z,r.kind);
        const double yn=heightAt(source,x,y-1,z,r.kind), yp=heightAt(source,x,y+1,z,r.kind);
        h[0]=average(source,hs,yn,xn,x-1,y-1,z,r.kind);
        h[1]=average(source,hs,yn,xp,x+1,y-1,z,r.kind);
        h[2]=average(source,hs,yp,xp,x+1,y+1,z,r.kind);
        h[3]=average(source,hs,yp,xn,x-1,y+1,z,r.kind);
    }
    FluidGeometry result;
    const double faceHeight[6] = {*std::min_element(h,h+4),8.0/9.0,
        std::max(h[1],h[2]),std::max(h[0],h[3]),std::max(h[3],h[2]),std::max(h[0],h[1])};
    for (unsigned f=0; f<6; ++f) {
        const auto& n=source.fluid(x+Off[f][0],y+Off[f][1],z+Off[f][2]);
        if (n.kind != r.kind && (f == 0 || !covered(self,f^1,1)) && !covered(n,f,faceHeight[f]))
            result.mask |= 1u<<f;
    }
    for (auto& v : h) v=std::max(v-((result.mask&1) ? r.offset : 0),0.0);
    double topUV[4][2]={{0,16},{16,16},{16,0},{0,0}};
    bool flowing=false;
    if ((result.mask&1) && r.flow) {
        double fx=flowDistance(source,x+1,y,z,self)-flowDistance(source,x-1,y,z,self);
        double fy=flowDistance(source,x,y+1,z,self)-flowDistance(source,x,y-1,z,self);
        double length=std::sqrt(fx*fx+fy*fy);
        if (length > .000001) { fx/=length; fy/=length; } else { fx=0; fy=0; }
        bool falling=false;
        if (self.falling) for (unsigned f=2; f<6; ++f) for (int dz=0; dz<=1; ++dz) {
            const auto& n=source.fluid(x+Off[f][0],y+Off[f][1],z+dz);
            falling |= n.kind != r.kind && !n.ice && (n.sturdy & (1u<<f));
        }
        length=std::sqrt(fx*fx+fy*fy+(falling ? 36 : 0));
        if (length > .000001) { fx/=length; fy/=length; } else { fx=0; fy=0; }
        flowing=std::abs(fx)>.000001 || std::abs(fy)>.000001;
        if (flowing) {
            const double angle=std::atan2(fy,fx)-std::acos(-1.0)*.5;
            const double s=std::sin(angle)*.25,c=std::cos(angle)*.25;
            const double uv[4][2]={{(.5-c-s)*16,(.5-c+s)*16},{(.5+c-s)*16,(.5-c-s)*16},
                {(.5+c+s)*16,(.5+c-s)*16},{(.5-c+s)*16,(.5+c+s)*16}};
            for (unsigned i=0; i<4; ++i) std::copy(uv[i],uv[i]+2,topUV[i]);
        }
    }
    for (unsigned f=0; f<6; ++f) if (result.mask & (1u<<f)) {
        auto& t=result.faces[f];
        t.mode=3; t.face=int(f); t.flatShade=int(r.shade[f]); t.emission=int(r.emission);
        for (unsigned a=0; a<3; ++a) t.normal[a]=float(Off[f][a]);
        double lightCorners[4][3];
        for (unsigned i=0; i<4; ++i) {
            const auto& corner=Corners[f][i];
            std::copy(corner,corner+3,lightCorners[i]);
            auto& v=t.positions[i];
            std::copy(corner,corner+3,v);
            if (corner[2] != 0) {
                const unsigned hi=corner[1] == 0 ? unsigned(corner[0]) : 3-unsigned(corner[0]);
                v[2]=lightCorners[i][2]=h[hi];
            } else v[2]=(result.mask&2) ? r.offset : 0;
            if (f>=2) v[f<4 ? 0 : 1] += f%2==0 ? -r.offset : r.offset;
            double raw[2]={i==0 || i==3 ? 0.0 : 16.0, i<2 ? 16.0 : std::clamp((1-v[2])*16,0.0,16.0)};
            if (f<2) { raw[0]=topUV[i][0]; raw[1]=topUV[i][1]; }
            if (f==1) { raw[0]=i==0 || i==3 ? 0.0 : 16.0; raw[1]=i<2 ? 16.0 : 0.0; }
            const auto& tile=r.tiles[f==0 && flowing ? 6 : f];
            for (unsigned a=0; a<2; ++a) {
                double uv=tile.origin[a]+raw[a]*tile.scale[a];
                if (raw[a]<=0) uv+=tile.inset[a]; else if (raw[a]>=16) uv-=tile.inset[a];
                t.uv[i][a]=float(uv);
            }
            double best=std::numeric_limits<double>::max();
            for (unsigned j=0; j<4; ++j) {
                double distance=0;
                for (unsigned a=0; a<3; ++a) { const double d=lightCorners[i][a]-Corners[f][j][a]; distance+=d*d; }
                if (distance<best) { best=distance; t.indices[i]=j; }
            }
            for (unsigned a=0; a<3; ++a) t.extent[a]=std::max(t.extent[a],std::abs(v[a]));
        }
        const auto low=*std::min_element(h,h+4), high=*std::max_element(h,h+4);
        t.flags=(r.full || f!=0 || (high-low<=Epsilon && high>1-Epsilon)) ? 1 : 0;
    }
    return result;
}
}
