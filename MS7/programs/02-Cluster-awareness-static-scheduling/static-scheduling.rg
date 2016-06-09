-- Static scheduling demo.
--
-- Copyright (C) 2016 Braam Research, LLC.

import "regent"

local support = terralib.includec("static-scheduling-support.h",{})

task bottom_level(cpu, i : int, j : int)
    support.node_log("Bottom level task %d/%d/%d, SLURM node %d, SLURM task %d", cpu, i, j, support.current_slurm_node(), support.current_slurm_task());
end

task level_1_task(cpu : int, i : int)
    support.node_log("Level 1 task %d/%d, SLURM node %d, SLURM task %d", cpu, i, support.current_slurm_node(), support.current_slurm_task());
    __demand(__parallel)
    for j=0, 5 do
        level_2_task(cpu, i, j)
    end
end

task level_0_task(cpu : int)
    support.node_log("Root task %d. SLURM node %d, SLURM task %d", cpu, support.current_slurm_node(), support.current_slurm_task())
    for i=0, 2 do
        level_1_task(cpu, i)
    end
end

task start_task()
    support.node_log("starting everything");
    -- ask runtime to not wait while we are working.
    __demand(__parallel)
    for cpu_index=0, 4 do
        level_0_task(cpu)
    end
end

-- Register mappers and setup support vars.
support.register_mappers()

-- start main work.
regentlib.start(start_task)