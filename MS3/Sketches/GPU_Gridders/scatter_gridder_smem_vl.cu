#include "scatter_gridder.h"

__device__ double atomicAdd(double* address, double val)
{
#ifdef FAKE_ATOMIC
  double orig = *address;
  *address = orig + val;
  return orig;
#else
  unsigned long long int* address_as_ull = (unsigned long long int*)address;
  unsigned long long int old = *address_as_ull, assumed;
  do {
       assumed = old;
       old = atomicCAS(address_as_ull, assumed,
                         __double_as_longlong(val +
                           __longlong_as_double(assumed)));
       // Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
  } while (assumed != old);
  return __longlong_as_double(old);
#endif
}

__device__ __inline__ void atomicAdd(Double4c *ptr, complexd sumXX, complexd sumXY, complexd sumYX, complexd sumYY)
{
  atomicAdd(&ptr->XX.x, sumXX.x);
  atomicAdd(&ptr->XX.y, sumXX.y);
  atomicAdd(&ptr->XY.x, sumXY.x);
  atomicAdd(&ptr->XY.y, sumXY.y);
  atomicAdd(&ptr->YX.x, sumYX.x);
  atomicAdd(&ptr->YX.y, sumYX.y);
  atomicAdd(&ptr->YY.x, sumYY.x);
  atomicAdd(&ptr->YY.y, sumYY.y);
}

struct Pregridded
{
  short u;
  short v;
  int gcf_layer_offset;
};

template <int n> struct w_traits {
  typedef double3 uvw_type;
  static const int wplanes = n;
  static __inline__ __device__ int get_wplane(const uvw_type & coords) {
    return __double2int_rz(coords.z);
  }
};

template <> struct w_traits<1> {
  typedef double2 uvw_type;
  static const int wplanes = 1;
  static __inline__ __device__ int get_wplane(const uvw_type & coords) {
    return 0;
  }
};


template <
    int w_planes
  , int over
  >
__inline__ __device__ void loadIntoSharedMem (
    const w_traits<w_planes>::uvw_type * uvwp
  , const Double4c * visp
  , Pregridded * uvo_sharedp
  , Double4c * vis_sharedp
  , int n
  ) {
  for (int i = threadIdx.x; i < n; i += blockDim.x) {
    w_traits<w_planes>::uvw_type coords = uvwp[i];
    int
        u = __double2int_rz(coords.x)
      , v = __double2int_rz(coords.y)
      , over_u = __double2int_rz(over * (coords.x - u))
      , over_v = __double2int_rz(over * (coords.y - v))
      ;
    uvo_sharedp[i] = {short(u), short(v), (w_traits<w_planes>::get_wplane(coords) * over + over_u) * over + over_v};
    vis_sharedp[i] = visp[i];
  }
}

template <
    int w_planes
  , int max_supp
  , int grid_size
  , int over
  >
__inline__ __device__
// grid must be initialized to 0s.
void gridKernel_scatter_kernel(
    const complexd gcf[w_planes][over][over][max_supp][max_supp]
  , Double4c grid[grid_size][grid_size]
  , const Pregridded * uvwp
  , const Double4c * visp
  , int n
  , int myU
  , int myV
  ) {
  complexd
      sumXX = {0, 0}
    , sumXY = {0, 0}
    , sumYX = {0, 0}
    , sumYY = {0, 0}
    ;
  int
      grid_point_u = 0
    , grid_point_v = 0;

  for (int i = 0; i < n; i++) {
    int myConvU, myConvV, myGridU, myGridV, u, v;
    u = uvwp[i].u;
    v = uvwp[i].v;
    myConvU = myU - u % max_supp;
    if (myConvU < 0) myConvU += max_supp;
    myConvV = myV - v % max_supp;
    if (myConvV < 0) myConvV += max_supp;
    // Like Romein we leave grid shifted by max_supp/2 because
    // we need to shift it anyway to 0-center it for FFT.
    // We will make this in a single take later.
    myGridU = u + myConvU;
    myGridV = v + myConvV;
    complexd supportPixel = (gcf[0][0][0] + uvwp[i].gcf_layer_offset)[myConvU][myConvV];
    if (myGridU != grid_point_u || myGridV != grid_point_v) {
      atomicAdd(&grid[grid_point_u][grid_point_v], sumXX, sumXY, sumYX, sumYY);
        sumXX
      = sumXY
      = sumYX
      = sumYY
      = {0, 0};
      grid_point_u = myGridU;
      grid_point_v = myGridV;
    }
    #define __ADD_SUPP(pol) sum##pol = cuCfma(supportPixel, visp[i].pol, sum##pol)
    __ADD_SUPP(XX);
    __ADD_SUPP(XY);
    __ADD_SUPP(YX);
    __ADD_SUPP(YY);
  }
  atomicAdd(&grid[grid_point_u][grid_point_v], sumXX, sumXY, sumYX, sumYY);
}

/*
  Suitable only for max_supp <= 32.
  Must be launched as:
  ...
  dim3 blockDim(max_supp, max_supp);
  gridKernel_scatter_small<<<baselines, blockDim ... >>>
  ...
 */
template <
    int w_planes
  , int max_supp
  , int grid_size
  , int over
  , int max_samples_n
  >
__global__
// grid must be initialized to 0s.
void gridKernel_scatter_small(
    const complexd gcf[w_planes][over][over][max_supp][max_supp]
  , Double4c grid[grid_size][grid_size]
  , const w_traits<w_planes>::uvw_type * uvwp
  , const Double4c * visp
  , int n // Should be <= max_samples_n! It is enforced by the caller.
  ) {
  __shared__ Pregridded uvo_shared[max_samples_n];
  __shared__ Double4c vis_shared[max_samples_n];
  
  loadIntoSharedMem<
       w_planes
     , over
     >(uvwp, visp, uvo_shared, vis_shared, n);

  syncthreads();

  gridKernel_scatter_kernel<
      w_planes
    , max_supp
    , grid_size
    , over
    > (gcf, grid, uvo_shared, vis_shared, n, threadIdx.x, threadIdx.y);
}

// Test instantiation
template __global__ void gridKernel_scatter_small<32, 64, 2048, 8, 200>(
    const complexd gcf[32][8][8][64][64]
  , Double4c grid[2048][2048]
  , const w_traits<32>::uvw_type *uvwp
  , const Double4c * visp
  , int n
  );

/*
  Suitable for any max_supp.
  Essentially the same as gridKernel_scatter_small
  but with extra cycle along support dims (we follow Romein here).

  In fact we can simply introduce another grid (of blocks) dimension
  to cover necessary support range and add check if we are within
  our support range (and that would be even simpler than Romein's approach)
  but at the moment we simply use Romein's approach.

  Must be launched as:
  ...
  #define MAX_THREADS_PER_BLOCK 1024
  gridKernel_scatter<<<baselines, MAX_THREADS_PER_BLOCK ... >>>
  ...
  */
template <
    int w_planes
  , int max_supp
  , int grid_size
  , int over
  , int max_samples_n
  >
__global__
// grid must be initialized to 0s.
void gridKernel_scatter(
    const complexd gcf[w_planes][over][over][max_supp][max_supp]
  , Double4c grid[grid_size][grid_size]
  , const w_traits<w_planes>::uvw_type * uvwp
  , const Double4c * visp
  , int n // Should be <= max_samples_n! It is enforced by the caller.
  ) {
  __shared__ Pregridded uvo_shared[max_samples_n];
  __shared__ Double4c vis_shared[max_samples_n];
  
  loadIntoSharedMem<
       w_planes
     , over
     >(uvwp, visp, uvo_shared, vis_shared, n);

  syncthreads();

  for (int i = threadIdx.x; i < max_supp * max_supp; i += blockDim.x) {
    int
        myU = i % max_supp
      , myV = i / max_supp
      ;
    gridKernel_scatter_kernel<
        w_planes
      , max_supp
      , grid_size
      , over
      > (gcf, grid, uvo_shared, vis_shared, n, myU, myV);
  }
}

// Test instantiation
template __global__ void gridKernel_scatter<32, 64, 2048, 8, 200>(
    const complexd gcf[32][8][8][64][64]
  , Double4c grid[2048][2048]
  , const w_traits<32>::uvw_type *uvwp
  , const Double4c * visp
  , int n
  );
