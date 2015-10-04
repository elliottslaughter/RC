#ifdef _MSC_VER
#include <vector>
#endif

#include <cstring>
#include <array>

#include <omp.h>

#include "uvg_full.h"
#include "mkHalideBuf.h"

#include "scatter_gridder_w_dependent_dyn_1p_halide_full.h"

using namespace std;

#define __tod(a, ...) reinterpret_cast<__VA_ARGS__ double *>(a)

const int over = 8;
void gridKernel_scatter_halide_full(
    double scale
  , double wstep
  , int baselines
  , const int bl_supps[/* baselines */]
  , complexd grid[]
    // GCF *data* ptr
    // packed [over][over][gcf_supp][gcf_supp] arrays
    // we have w-planes of them. gcf varies between w-plane values.
    // Halide gridder computes all offsets into it
  , const complexd gcf[]
  , const Double3 uvw[]
  , const complexd vis[]
  , int ts_ch
  , int grid_pitch
  , int grid_size
  , int gcf_supps[]
  // Provisional.
  // Needed only to compute gcf layers offsets.
  , int wplanes
  ) {
  #ifndef _MSC_VER
    int gcf_offs_[wplanes];
    #define gcf_offs gcf_offs_
  #else
    vector<int> gcf_offs_(wplanes);
    #define gcf_offs gcf_offs_.data()
  #endif
  int off = 0;
  for(int wp = 0; wp < wplanes; wp++){
    gcf_offs_[wp] = off;
    off += over * over * gcf_supps[wp] * gcf_supps[wp];
  }

  buffer_t blsup_buf = mkHalideBuf(bl_supps, baselines);
  buffer_t gcfsup_buf = mkHalideBuf(gcf_supps, wplanes);
  centerHalideBuf(&gcfsup_buf, wplanes/2);
  buffer_t gcfoff_buf = mkHalideBuf(gcf_offs, wplanes);
  centerHalideBuf(&gcfoff_buf, wplanes/2);
  auto gcf_buf = mkInterleavedHalideBufs<2>(__tod(gcf, const), off);
  buffer_t uvw_buf = mkHalideBuf<3>(__tod(uvw, const), baselines, ts_ch);
  buffer_t vis_buf = mkHalideBuf<2>(__tod(vis, const), baselines, ts_ch);
  buffer_t grid_buf = mkHalideBufPadded<2>(__tod(grid), grid_size, grid_pitch-grid_size);

  uvg_full(
      scale
    , wstep
    , baselines
    , &blsup_buf
    , ts_ch
    , grid_size
    , &gcfsup_buf
    , &uvw_buf
    , &vis_buf
    , off
    , wplanes/2
    , &gcfoff_buf
    , &gcf_buf[0]
    , &gcf_buf[1]
    , &grid_buf
    );
}
