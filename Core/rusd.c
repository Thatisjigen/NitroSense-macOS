// rusd.c: one read-only sample of the RTX telemetry (temperature, power, clocks, P-state) from RM's user shared data page,
// class NV00DE, "RUSD": no root, no kext of ours, no write to the GPU.
//
// A client is opened, the page is allocated with polling on, read and freed, and the client is closed, each time. Measured on
// this machine with nobody else polling: setup 5 ms; the values are there as soon as the allocation returns;
// with the object alive RM polls at 0.1 s, then every 0.5 s, for as long as it lives; after the free the timestamps go back
// to 0 and nothing moves. So a sample costs one poll, and between samples RM does not poll at all, which a long-lived object
// would make it do. The structures come from NVIDIA's open-gpu-kernel-modules 615.78.08, the RM our NVRM runs; if the driver
// reports another version nothing is read, because the page layout may differ.
//
// The transport (the user client and its escapes) comes from src/rm.c of https://github.com/Thatisjigen/nvenc:
//
//   MIT License. Copyright (c) 2026 mickys
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
//   rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
//   Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
//   WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//   COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
//   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// The idea of reading RUSD from user space comes from nvgfx-smi in NvGfx (https://github.com/watchthelight-labs/NvGfx,
// PolyForm Noncommercial): no code of it is here.

#include "rusd.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "nvtypes.h"
#include "nvmisc.h"
#include "nvos.h"
#include "nvstatus.h"
#include "nv-ioctl.h"
#include "nv-ioctl-numbers.h"
#include "nv_escape.h"
#include "nv-unix-nvos-params-wrappers.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "class/cl00de.h"
#include "ctrl/ctrl0000/ctrl0000gpu.h"

#define RM_HEADERS_VERSION "615.78.08"

enum { SEL_ESC = 1, SEL_BINDFD = 3 };
enum { STEP_OK, STEP_CLIENT, STEP_QUERY, STEP_CARD, STEP_VERSION, STEP_ROOT, STEP_ID, STEP_DEVICE, STEP_SUBDEVICE, STEP_ALLOC, STEP_MAP, STEP_EMPTY };

const char *nitroRUSDStepName(int32_t step) {
    switch (step) {
    case STEP_OK: return "read";
    case STEP_CLIENT: return "no NVAccel user client: is the RTX driver up?";
    case STEP_QUERY: return "the driver did not answer: is the RTX up?";
    case STEP_CARD: return "the driver reports no card";
    case STEP_VERSION: return "the driver's RM is not " RM_HEADERS_VERSION ": this build does not know its page layout";
    case STEP_ROOT: return "no RM client";
    case STEP_ID: return "no GPU id";
    case STEP_DEVICE: return "no RM device";
    case STEP_SUBDEVICE: return "no RM subdevice";
    case STEP_ALLOC: return "RM refused the shared data page";
    case STEP_MAP: return "the shared data page could not be mapped";
    case STEP_EMPTY: return "RM left the shared data page empty";
    default: return "unknown";
    }
}

typedef struct { io_connect_t conn; int fd; } Conn;

// NVAccel's bridge (0x4E56xxxx, type 0 = control); the user client keys its RM file on an fd number.
static int conn_open(Conn *c) {
    c->conn = 0;
    c->fd = -1;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0x4E560000u, &c->conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { c->conn = 0; return -1; }
    c->fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    uint64_t in = (uint64_t)c->fd;
    IOConnectCallScalarMethod(c->conn, SEL_BINDFD, &in, 1, NULL, NULL);
    return 0;
}

static void conn_close(Conn *c) {
    if (c->conn) IOServiceClose(c->conn);
    if (c->fd >= 0) close(c->fd);
}

static int esc(Conn *c, NvU32 cmd, void *data, size_t size) {
    uint64_t in = cmd;
    size_t out = size;
    return IOConnectCallMethod(c->conn, SEL_ESC, &in, 1, data, size, NULL, NULL, data, &out) == KERN_SUCCESS ? 0 : -1;
}

static NV_STATUS rm_alloc(Conn *c, NvHandle client, NvHandle parent, NvHandle *object, NvU32 cls, void *params, NvU32 size) {
    NVOS21_PARAMETERS p = { .hRoot = client, .hObjectParent = parent, .hObjectNew = *object, .hClass = cls, .pAllocParms = params, .paramsSize = size };
    if (esc(c, NV_ESC_RM_ALLOC, &p, sizeof p)) return NV_ERR_GENERIC;
    *object = p.hObjectNew;
    return p.status;
}

// One section of the page with the timestamp seqlock of cl00de.h; false until RM has filled it in.
#define READ_SECTION(page, field, dst) RUSD_READ_DATA((page), field, (dst))

void nitroRUSDSample(NitroRUSDSample *out) {
    memset(out, 0, sizeof *out);
    out->tempC = out->memTempC = out->powerW = out->avgPowerW = -1;
    out->pstate = -1;

    Conn ctl = { 0, -1 }, mapping = { 0, -1 };
    NvHandle client = 0, device = 0x4E560001, subdevice = 0x4E560002, shared = 0x4E560003;
    NV00DE_SHARED_DATA *page = NULL;
    NvP64 stub = NvP64_NULL;
    NV_STATUS st;
#define FAIL(which, status) do { out->step = (which); out->rmStatus = (status); goto done; } while (0)

    if (conn_open(&ctl)) FAIL(STEP_CLIENT, 0);

    nv_ioctl_rm_api_version_t version;
    memset(&version, 0, sizeof version);
    version.cmd = NV_RM_API_VERSION_CMD_QUERY;
    if (esc(&ctl, NV_ESC_CHECK_VERSION_STR, &version, sizeof version)) FAIL(STEP_QUERY, 0);
    if (strncmp(version.versionString, RM_HEADERS_VERSION, sizeof version.versionString)) FAIL(STEP_VERSION, 0);

    nv_ioctl_card_info_t card;
    memset(&card, 0, sizeof card);
    if (esc(&ctl, NV_ESC_CARD_INFO, &card, sizeof card) || !card.valid) FAIL(STEP_CARD, 0);

    if ((st = rm_alloc(&ctl, 0, 0, &client, NV01_ROOT_CLIENT, NULL, 0))) { client = 0; FAIL(STEP_ROOT, st); }

    NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS id;
    memset(&id, 0, sizeof id);
    id.gpuId = card.gpu_id;
    NVOS54_PARAMETERS control = { .hClient = client, .hObject = client, .cmd = NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, .params = &id, .paramsSize = sizeof id };
    if (esc(&ctl, NV_ESC_RM_CONTROL, &control, sizeof control) || control.status) FAIL(STEP_ID, control.status);

    NV0080_ALLOC_PARAMETERS deviceParams;
    memset(&deviceParams, 0, sizeof deviceParams);
    deviceParams.deviceId = id.deviceInstance;
    deviceParams.hClientShare = client;
    if ((st = rm_alloc(&ctl, client, client, &device, NV01_DEVICE_0, &deviceParams, sizeof deviceParams))) FAIL(STEP_DEVICE, st);

    NV2080_ALLOC_PARAMETERS subdeviceParams;
    memset(&subdeviceParams, 0, sizeof subdeviceParams);
    subdeviceParams.subDeviceId = id.subDeviceInstance;
    if ((st = rm_alloc(&ctl, client, device, &subdevice, NV20_SUBDEVICE_0, &subdeviceParams, sizeof subdeviceParams))) FAIL(STEP_SUBDEVICE, st);

    NV00DE_ALLOC_PARAMETERS sharedParams;
    memset(&sharedParams, 0, sizeof sharedParams);
    sharedParams.polledDataMask = NV00DE_RUSD_POLL_THERMAL | NV00DE_RUSD_POLL_POWER | NV00DE_RUSD_POLL_CLOCK | NV00DE_RUSD_POLL_PERF;
    if ((st = rm_alloc(&ctl, client, subdevice, &shared, RM_USER_SHARED_DATA, &sharedParams, sizeof sharedParams))) FAIL(STEP_ALLOC, st);

    // The mapping goes through a second connection, named by its fd number, and only for reading.
    if (conn_open(&mapping)) FAIL(STEP_MAP, 0);
    nv_ioctl_nvos33_parameters_with_fd map = { .params = { .hClient = client, .hDevice = subdevice, .hMemory = shared, .offset = 0,
        .length = sizeof(NV00DE_SHARED_DATA), .flags = DRF_DEF(OS33, _FLAGS, _ACCESS, _READ_ONLY) }, .fd = mapping.fd };
    if (esc(&ctl, NV_ESC_RM_MAP_MEMORY, &map, sizeof map) || map.params.status) FAIL(STEP_MAP, map.params.status);
    stub = map.params.pLinearAddress;
    mach_vm_address_t address = 0;
    mach_vm_size_t length = 0;
    if (IOConnectMapMemory64(mapping.conn, 0, mach_task_self(), &address, &length, kIOMapAnywhere | kIOMapReadOnly) != KERN_SUCCESS) FAIL(STEP_MAP, 0);
    page = (NV00DE_SHARED_DATA *)(uintptr_t)address;
    if (length < sizeof(NV00DE_SHARED_DATA)) FAIL(STEP_MAP, 0);

    RUSD_TEMPERATURE temp;
    // RM fills the page in while it allocates it; the wait is only in case that ever changes, and stays under one poll.
    bool filled = READ_SECTION(page, temperatures[RUSD_TEMPERATURE_TYPE_GPU], &temp);
    for (int tries = 0; !filled && tries < 15; tries++) {
        usleep(20 * 1000);
        filled = READ_SECTION(page, temperatures[RUSD_TEMPERATURE_TYPE_GPU], &temp);
    }
    if (!filled) FAIL(STEP_EMPTY, 0);
    out->tempC = temp.temperature / 256.0;  // NvTemp is 24.8 fixed point
    if (READ_SECTION(page, temperatures[RUSD_TEMPERATURE_TYPE_MEMORY], &temp)) out->memTempC = temp.temperature / 256.0;

    RUSD_INST_POWER_USAGE inst;
    if (READ_SECTION(page, instPowerUsage, &inst) && inst.info.instGpuPower) out->powerW = inst.info.instGpuPower / 1000.0;
    RUSD_AVG_POWER_USAGE avg;
    if (READ_SECTION(page, avgPowerUsage, &avg) && avg.info.averageGpuPower) out->avgPowerW = avg.info.averageGpuPower / 1000.0;

    RUSD_CLK_PUBLIC_DOMAIN_INFOS clocks;
    if (READ_SECTION(page, clkPublicDomainInfos, &clocks)) {
        out->gpcMHz = clocks.info[RUSD_CLK_PUBLIC_DOMAIN_GRAPHICS].actualClkKHz / 1000;
        out->memMHz = clocks.info[RUSD_CLK_PUBLIC_DOMAIN_MEMORY].actualClkKHz / 1000;
    }
    RUSD_PERF_CURRENT_PSTATE pstate;
    if (READ_SECTION(page, perfCurrentPstate, &pstate) && pstate.currentPstate) out->pstate = __builtin_ctz(pstate.currentPstate);  // bit n = Pn

done:
    if (page) {
        IOConnectUnmapMemory64(mapping.conn, 0, mach_task_self(), (mach_vm_address_t)(uintptr_t)page);
        NVOS34_PARAMETERS unmap = { .hClient = client, .hDevice = subdevice, .hMemory = shared, .pLinearAddress = stub };
        esc(&ctl, NV_ESC_RM_UNMAP_MEMORY, &unmap, sizeof unmap);
    }
    if (client) {
        // Freeing the client frees everything under it, and with the last object RM stops polling.
        NVOS00_PARAMETERS free = { .hRoot = client, .hObjectParent = client, .hObjectOld = client };
        esc(&ctl, NV_ESC_RM_FREE, &free, sizeof free);
    }
    conn_close(&mapping);
    conn_close(&ctl);
#undef FAIL
}
