#include <cstring>

#if defined _OPENMP
#include <omp.h>
#else
#define omp_get_thread_num()  0
#endif

#ifdef _MSC_VER
#pragma warning(disable:4127)
#endif
#define __DYN_GRID_SIZE
#include "common.h"
#include "metrix.h"
#include "OskarBinReader.h"
#include "aligned_malloc.h"

#define as256p(p) (reinterpret_cast<__m256d*>(p))
#define as256pc(p) (reinterpret_cast<const __m256d*>(p))

inline
void addGrids(
    complexd dst[]
  , const complexd srcs[]
  , int nthreads
  , int grid_pitch
  , int grid_size
  )
{
  int siz = grid_size*grid_pitch;
#pragma omp parallel for
  for (unsigned int i = 0; i < siz*sizeof(complexd)/(256/8); i++) {
    __m256d sum = as256pc(srcs)[i];
    // __m256d sum = _mm256_loadu_pd(reinterpret_cast<const double*>(as256pc(srcs)+i));

    for (int g = 1; g < nthreads; g ++)
      sum = _mm256_add_pd(sum, as256pc(srcs + g * siz)[i]);

    as256p(dst)[i] = sum;
  }
}

// We could simply use pointer-to-function template
// but most C++ compilers seem to produce worse code
// in such a case. Thus we wrap it in a class.
template <
    int over
  , bool do_mirror
  , typename Inp
  > struct cvt {};

template <
    int over
  , bool do_mirror
  > struct cvt<over, do_mirror, Pregridded> {
  static void pre(double, double, Pregridded inp, Pregridded & outpr, int) {outpr = inp;}
};

template <
    int over
  , bool do_mirror
  > struct cvt<over, do_mirror, Double3> {
  static void pre(double scale, double wstep, Double3 inp, Pregridded & outpr, int grid_size) {
    pregridPoint<over, do_mirror>(scale, wstep, inp, outpr, grid_size);
  }
};

template <
    int over
  , bool is_half_gcf
  , bool use_permutations

  , typename Inp
  >
// grid must be initialized to 0s.
void psfiKernel_scatter(
    double scale
  , double wstep
  , int baselines
  , const BlWMap permutations[/* baselines */]
  , complexd grids[]
    // We have a [w_planes][over][over]-shaped array of pointers to
    // variable-sized gcf layers, but we precompute (in pregrid)
    // exact index into this array, thus we use plain pointer here
  , const complexd * gcf[]
  , const Inp _uvw[]
  , int ts_ch
  , int grid_pitch
  , int grid_size
  ) {
  int siz = grid_size*grid_pitch;
#pragma omp parallel
  {
    complexd * _grid = grids + omp_get_thread_num() * siz;
    memset(_grid, 0, sizeof(complexd) * siz);
    __ACC(complexd, grid, grid_pitch);

#pragma omp for schedule(dynamic)
    for(int bl0 = 0; bl0 < baselines; bl0++) {
      int bl;
      if (use_permutations) bl = permutations[bl0].bl;
      else bl = bl0;
      int max_supp_here;
      max_supp_here = get_supp(permutations[bl].wp);
      const Inp * uvw;
      uvw = _uvw + bl*ts_ch;

      for (int su = 0; su < max_supp_here; su++) { // Moved from 2-levels below according to Romein
        for (int i = 0; i < ts_ch; i++) {
            Pregridded p;
            cvt<over, is_half_gcf, Inp>::pre(scale, wstep, uvw[i], p, grid_size);

          for (int sv = 0; sv < max_supp_here; sv++) {
            // Don't forget our u v are already translated by -max_supp_here/2
            int gsu, gsv;
            gsu = p.u + su;
            gsv = p.v + sv;

            complexd supportPixel;
            #define __layeroff su * max_supp_here + sv
            if (is_half_gcf) {
              int index;
              index = p.gcf_layer_index;
              // Negative index indicates that original w was mirrored
              // and we shall negate the index to obtain correct
              // offset *and* conjugate the result.
              if (index < 0) {
                supportPixel = conj(gcf[-index][__layeroff]);
              } else {
                supportPixel = gcf[index][__layeroff];
              }
            } else {
                supportPixel = gcf[p.gcf_layer_index][__layeroff];
            }

            grid[gsu][gsv] += supportPixel;
          }
        }
      }
    }
  }
}


template <
    int over
  , bool is_half_gcf
  , bool use_permutations

  , typename Inp
  >
// grid must be initialized to 0s.
void psfiKernel_scatter_full(
    double scale
  , double wstep
  , int baselines
  , const BlWMap permutations[/* baselines */]
  , complexd grid[]
    // We have a [w_planes][over][over]-shaped array of pointers to
    // variable-sized gcf layers, but we precompute (in pregrid)
    // exact index into this array, thus we use plain pointer here
  , const complexd * gcf[]
  , const Inp uvw[]
  , int ts_ch
  , int grid_pitch
  , int grid_size
  ) {
#if defined _OPENMP
  int siz = grid_size*grid_pitch;
  int nthreads;

#pragma omp parallel
#pragma omp single
  nthreads = omp_get_num_threads();

  // Nullify incoming grid, allocate thread-local grids
  memset(grid, 0, sizeof(complexd) * siz);
  complexd * tmpgrids = alignedMallocArray<complexd>(siz * nthreads, 32);
  
  psfiKernel_scatter<
      over
    , is_half_gcf
    , use_permutations

    , Inp
    >(scale, wstep, baselines, permutations, tmpgrids, gcf, uvw, ts_ch, grid_pitch, grid_size);
  addGrids(grid, tmpgrids, nthreads, grid_pitch, grid_size);
  free(tmpgrids);
#else
  psfiKernel_scatter<
      over
    , is_half_gcf
    , use_permutations

    , Inp
    >(scale, wstep, baselines, permutations, grid, gcf, uvw, ts_ch, grid_pitch, grid_size);
#endif
}

#define psfiKernelCPU(hgcfSuff, isHgcf, permSuff, isPerm)  \
extern "C"                                                 \
void gridKernelCPU##hgcfSuff##permSuff(                    \
    double scale                                           \
  , double wstep                                           \
  , int baselines                                          \
  , const BlWMap permutations[/* baselines */]             \
  , complexd grid[]                                        \
  , const complexd * gcf[]                                 \
  , const Double3 uvw[]                                    \
  , int ts_ch                                              \
  , int grid_pitch                                         \
  , int grid_size                                          \
  ){                                                       \
  psfiKernel_scatter_full<OVER, isHgcf, isPerm>            \
    ( scale, wstep, baselines, permutations                \
    , grid, gcf, uvw, ts_ch, grid_pitch, grid_size);       \
}

psfiKernelCPU(HalfGCF, true, Perm, true)
psfiKernelCPU(HalfGCF, true, , false)
psfiKernelCPU(FullGCF, false, Perm, true)
psfiKernelCPU(FullGCF, false, , false)
