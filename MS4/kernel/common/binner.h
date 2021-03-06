#ifndef __BINNER_H
#define __BINNER_H

#include "common.h"

// We assume we have the data for a single channel laid continuously in memory!
extern "C" {
void * bin(int num_points, double scale, double wstep, complexd* amps, Double3 * uvws, int gcfsupps[], int grid_size);
void * binm(int num_points, double scale, double wstep, complexd* amps, Double3 * uvws, int gcfsupps[], int grid_size);
}

#endif
