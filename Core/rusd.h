// One read-only sample of the RTX telemetry from RM's user shared data page. See rusd.c.
#ifndef NitroRUSD_h
#define NitroRUSD_h

#include <stdint.h>

typedef struct {
    int32_t step;        // 0: read. Otherwise the step that failed, see nitroRUSDStepName
    uint32_t rmStatus;   // the RM status of that step, if it had one
    double tempC;        // GPU, < 0 if RM did not fill it in
    double memTempC;     // memory, same
    double powerW;       // instantaneous, same
    double avgPowerW;    // RM's average, same
    uint32_t gpcMHz;     // graphics clock, 0 if not filled in
    uint32_t memMHz;     // memory clock, same
    int32_t pstate;      // 0-15, -1 if not filled in
} NitroRUSDSample;

// Opens an RM client, reads and frees everything again, in about 10 ms on this machine. Blocks while RM holds its locks,
// so never call it from the main thread.
void nitroRUSDSample(NitroRUSDSample *out);
const char *nitroRUSDStepName(int32_t step);

#endif
