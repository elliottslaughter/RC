#include "scatter_gridder.h"

template <
    int w_planes
  , int max_supp
  , int grid_size
  >
TaskCfg mkCfg (
    double min_u
  , double max_u
  , double min_v
  , double max_v
  , double min_w
  , double max_w
  , double min_freq
  , double max_freq
  ) {
  const int uv_shift_in_pixels = (max_supp + grid_size) / 2;
  double
      min_wavelength = SPEED_OF_LIGHT / max_freq
    , max_inverse_wave_length = max_freq / SPEED_OF_LIGHT
    , maxx_u = std::max(max_u, -min_u)
    , maxx_v = std::max(max_v, -min_v)
    , maxx0 = std::max(maxx_u, maxx_v)
    , maxx = maxx0 * max_freq / min_freq
    , cellsize = maxx / double (uv_shift_in_pixels)
    , cellsizeWL = cellsize * max_inverse_wave_length
    , scale = double (uv_shift_in_pixels) / maxx
    , scaleWL = scale * min_wavelength
    , w_step = (max_w - min_w) / double(w_planes) + WSTEP_CORRECT
    , w_stepWL = w_step * scaleWL
    , w_shift = -min_w
    , w_shiftWL = w_shift * scaleWL
    ;
  return {
      min_wavelength
    , max_inverse_wave_length
    , cellsize
    , cellsizeWL
    , scale
    , scaleWL
    , w_step
    , w_stepWL
    , w_shift
    , w_shiftWL
    };
}

struct Pregridded
{
  short u;
  short v;
  int gcf_layer_offset;
};

template <
    int w_planes
  , int max_supp
  , int grid_size
  , int over
  >
Pregridded pregrid(const Double3 & uvw, const TaskCfg & cfg) {
  double
      us = uvw.u * cfg.scaleWL
    , vs = uvw.v * cfg.scaleWL
    ;
  int
      u = int(us)
    , v = int(vs)
    , wplane = int((uvw.w + cfg.w_shift)/ cfg.w_step)
    , uv_shift_in_pixels = (max_supp + grid_size) / 2
    ;
  short
      fracu = short(double(over) * (us - double(u)))
    , fracv = short(double(over) * (vs - double(v)))
    ;

  // typedef complexd (*gcf_type)[w_planes][over][over][max_supp][max_supp];
  // return {u + uv_shift_in_pixels, v + uv_shift_in_pixels, (*(gcf_type)nullptr)[wplane][fracu][fracv] - (*(gcf_type)nullptr)[0][0][0]};
  const int overu = over;
  const int overv = over;
  return {u + uv_shift_in_pixels, v + uv_shift_in_pixels, ((wplane * overu + fracu) * overv + fracv) * max_supp};
}

template <
    int w_planes
  , int max_supp
  , int grid_size
  , int over

  , int baselines
  , int timesteps
  , int channels
  >
// grid must be initialized to 0s.
void gridKernel_scatter(
    const complexd gcf[w_planes][over][over][max_supp][max_supp]
  , Double4c grid[grid_size][grid_size]
  // , const Pregridded uvw[baselines][timesteps][channels]
  // , const Double4c vis[baselines][timesteps][channels]
  , const Pregridded uvw[baselines * timesteps * channels]
  , const Double4c vis[baselines * timesteps * channels]
  ) {
  for (int sv = 0; sv < max_supp; sv++) { // Moved from 2-levels below according to Romein
    for (int i = 0; i < baselines * timesteps * channels; i++) {
      auto gcf_layer = gcf[0][0][0] + uvw[i].gcf_layer_offset;
#ifdef __AVX__
      // We port Romein CPU code to doubles here (for MS2 we didn't)
      // vis0 covers XX and XY, vis1 -- YX and YY
      __m256d vis0 = _mm256_load_pd((const double *) &vis[i].XX);
      __m256d vis1 = _mm256_load_pd((const double *) &vis[i].YX);
#endif
      for (int su = 0; su < max_supp; su++) {
      // NOTE: Romein writes about moving this to the very outer scope
      // (2 levels up) to make things more cache-friendly.
      // I don't know whether it is cache frendly
      // but what I definitely see gcc generates 4-times shorter code for it!
      // We need to investigate this!
      // for (int sv = 0; sv < max_supp; sv++) {
        int gsu, gsv;
        gsu = uvw[i].u + su - max_supp/2;
        gsv = uvw[i].v + sv - max_supp/2;
#ifdef __AVX__
        __m256d weight_r = _mm256_set1_pd(gcf_layer[su][sv].real());
        __m256d weight_i = _mm256_set1_pd(gcf_layer[su][sv].imag());

        /* _mm256_permute_pd(x, 5) swaps adjacent doubles pairs of x:
           d0, d1, d2, d3 goes to d1, d0, d3, d2
         */
        #define __DO(p,f)                                     \
        __m256d * gridptr##p = (__m256d *) &grid[gsu][gsv].f; \
        __m256d tr##p = _mm256_mul_pd(weight_r, vis##p);      \
        __m256d ti##p = _mm256_mul_pd(weight_i, vis##p);      \
        __m256d tp##p = _mm256_permute_pd(ti##p, 5);          \
        __m256d t##p = _mm256_addsub_pd(tr##p, tp##p);        \
        gridptr##p[p] = _mm256_add_pd(gridptr##p[p], t##p)

        __DO(0, XX);
        __DO(1, YX);
#else
        #define __GRID_POL(pol) grid[gsu][gsv].pol += vis[i].pol * gcf_layer[su][sv]
        __GRID_POL(XX);
        __GRID_POL(XY);
        __GRID_POL(YX);
        __GRID_POL(YY);
#endif
      }
    }
  }
}

// Test instantiation
template void gridKernel_scatter<32, 64, 2048, 8, 50*99, 20, 1>(
    const complexd gcf[32][8][8][64][64]
  , Double4c grid[2048][2048]
  , const Pregridded uvw[(50*90) * 20 * 1]
  , const Double4c vis[(50*90) * 20 * 1]
  );
