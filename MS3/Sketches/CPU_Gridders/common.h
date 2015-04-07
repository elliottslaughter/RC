#ifndef __COMMON_H
#define __COMMON_H

#if defined __AVX__
#include <immintrin.h>
#endif

#ifdef __CUDACC__
  #include <cuComplex.h>
  typedef cuDoubleComplex complexd;
#elif defined __cplusplus
  #include <complex>
  typedef std::complex<double> complexd;
#else
  #include <complex.h>
  typedef double complex complexd;
#endif

struct Double4c
{
  complexd XX;
  complexd XY;
  complexd YX;
  complexd YY;
};

struct Double3
{
  double u;
  double v;
  double w;
};

struct Pregridded
{
  short u;
  short v;
  short gcf_layer_index;
  short gcf_layer_supp;
};

#ifdef __CUDACC__
__host__ __device__ __inline__ static 
#else
__inline static
#endif
  int get_supp(int w) {
    if (w < 0) w = -w;
    return w * 8 + 1;
  }

#if defined __cplusplus || defined __CUDACC__
template <
    int grid_size
  , int over
  , int w_planes
  , bool do_mirror
  >
#ifndef __CUDACC__
inline 
#else
// FIXME: this is a bit messy because of renaming.
// Investigate how to get rid of this better.
#define Double3 double3
#define u x
#define v y
#define w z
__inline__ __host__ __device__
#endif
static void pregridPoint(double scale, Double3 uvw, Pregridded & res){
    uvw.u *= scale;
    uvw.v *= scale;
    uvw.w *= scale;
    short
        w_plane = short(round (uvw.w / (w_planes/2)))
      , max_supp = short(get_supp(w_plane))
      // We additionally translate these u v by -max_supp/2
      // because gridding procedure translates them back
      , u = short(round(uvw.u) + grid_size/2 - max_supp/2)
      , v = short(round(uvw.v) + grid_size/2 - max_supp/2)
      , over_u = short(round(over * (uvw.u - u)))
      , over_v = short(round(over * (uvw.v - v)))
      ;
#ifndef __CUDACC__
    res.u = u;
    res.v = v;
#else
#undef u
#undef v
#undef w
    res.u = x;
    res.v = y;
#endif
    // Well, this is a kind of trick:
    // For full GCF we can have w_plane and hence gcf_layer_index negative.
    // But for half GCF we have both positive. Thus to convey an information
    // about original w being negative we negate the whole index.
    // When inspecting it client of half GCF if looking negative index should
    // both negate it *and* conjugate support pixel.
    if (do_mirror) {
      if (w_plane < 0) {
          res.gcf_layer_index = -((-w_plane * over + over_u) * over + over_v);
      } else {
          res.gcf_layer_index = (w_plane * over + over_u) * over + over_v;
      }
    } else {
      res.gcf_layer_index = (w_plane * over + over_u) * over + over_v;
    }
    res.gcf_layer_supp = max_supp;
}
#endif

// We have original u,v,w, in meters.
// To go to u,v,w in wavelengths we shall multiply them with freq/SPEED_OF_LIGHT

#ifndef SPEED_OF_LIGHT
#define SPEED_OF_LIGHT 299792458.0
#endif

#if __GNUC__ == 4 && __GNUC_MINOR__ < 6
#define __OLD
#endif

#ifdef __OLD
#define nullptr NULL
#endif

#endif