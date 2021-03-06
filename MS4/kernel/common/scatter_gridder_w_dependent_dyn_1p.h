#ifndef __SCATTER_GRIDDER_W_DEPENDENT_DYN_1P_H
#define __SCATTER_GRIDDER_W_DEPENDENT_DYN_1P_H

#include "common.h"

#ifdef __cplusplus
#define EXTERNC extern "C"
#else
#define EXTERNC
#endif

typedef unsigned long long ull;

#ifndef __DEGRID

#define gridKernelCPUDecl(hgcfSuff, isHgcf)               \
EXTERNC                                                   \
ull gridKernelCPU##hgcfSuff(                              \
    double scale                                          \
  , double wstep                                          \
  , int baselines                                         \
  , const int bl_supps[/* baselines */]                   \
  , complexd grid[]                                       \
  , const complexd * gcf[]                                \
  , const Double3 * uvw[]                                 \
  , const complexd * vis[]                                \
  , int ts_ch                                             \
  , int grid_pitch                                        \
  , int grid_size                                         \
  , int gcf_supps[]                                       \
  );

gridKernelCPUDecl(HalfGCF, true)
gridKernelCPUDecl(FullGCF, false)

EXTERNC
void grid0(
    const Double3 uvw[]
  , const complexd vis[]
  , complexd grid[]
  , double scale
  , int baselines_ts_ch
  , int grid_pitch
  , int grid_size
  );

EXTERNC
void normalizeCPU(
    complexd src[]
  , int grid_pitch
  , int grid_size
  );

EXTERNC
void reweight(
    const Double3 uvw[]
  ,       complexd vis[]
  , double scale
  , int baselines_ts_ch
  , int grid_size
  );

EXTERNC
void rotateCPU(
    const Double3 uvw[]
  ,       complexd vis[]
  , int baselines_ts_ch
  , double scale
  );

#else

#define deGridKernelCPUDecl(hgcfSuff, isHgcf)             \
EXTERNC                                                   \
ull deGridKernelCPU##hgcfSuff(                            \
    double scale                                          \
  , double wstep                                          \
  , int baselines                                         \
  , const int bl_supps[/* baselines */]                   \
  , const complexd grid[]                                 \
  , const complexd * gcf[]                                \
  , const Double3 * uvw[]                                 \
  , complexd * vis[]                                      \
  , int ts_ch                                             \
  , int grid_pitch                                        \
  , int grid_size                                         \
  , int gcf_supps[]                                       \
  );

deGridKernelCPUDecl(HalfGCF, true)
deGridKernelCPUDecl(FullGCF, false)

#endif

#endif
