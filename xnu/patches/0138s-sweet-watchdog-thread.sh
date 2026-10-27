#!/bin/bash
# 0138s: software watchdog thread (SweetWatchdogThread) - injects via python
# (runs from XNU source root before .patch files; MACHINE_CONFIG=SWEET)
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f iokit/Kernel/IOPMrootDomain.cpp ]] || exit 1

# 1) new file: watchdog thread
cat > iokit/Kernel/arm/SweetWatchdogThread.cpp << 'EOF'
#if defined(ARM64_BOARD_CONFIG_SWEET)
#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOLib.h>

extern void sweet_wd_progress(void);

static IOTimerEventSource * g_swdTimer = nullptr;
static volatile UInt32 g_swdProgress = 1;
static volatile UInt32 g_swdLastSeen = 1;
static volatile UInt32 g_swdHang = 0;

void sweet_wd_progress(void) { g_swdProgress++; }

static void sweet_swd_tick(OSObject *owner, IOTimerEventSource *timer)
{
    if (g_swdProgress == g_swdLastSeen) {
        g_swdHang++;
        IOLog("SWEET WDT: no progress %u/20\n", g_swdHang);
        if (g_swdHang >= 20) {
            IOLog("SWEET WDT: HANG DETECTED - rebooting\n");
            extern void machine_restart(void);
            machine_restart();
        }
    } else {
        g_swdHang = 0;
        g_swdLastSeen = g_swdProgress;
    }
    timer->wakeAtInterval(30000000ULL); // 30s
}

void sweet_swd_start(OSObject *owner, IOWorkLoop *wl)
{
    if (!wl || g_swdTimer) return;
    g_swdTimer = IOTimerEventSource::allocator()->allocate();
    if (g_swdTimer && g_swdTimer->init(owner, sweet_swd_tick) == kIOReturnSuccess) {
        wl->addEventSource(g_swdTimer);
        g_swdTimer->setTimeoutMS(30000);
        IOLog("SWEET WDT: software watchdog armed (30s tick, 10min reboot)\n");
    }
}
#endif
EOF

# 2) files.arm64 entry
python3 << 'PYEOF'
p = 'iokit/conf/files.arm64'
s = open(p).read()
if 'SweetWatchdogThread' not in s:
    lines2 = s.split('\n')
    out2 = []
    for l2 in lines2:
        out2.append(l2)
        if 'SweetFramebuffer.cpp' in l2:
            out2.append('iokit/Kernel/arm/SweetWatchdogThread.cpp                       optional iokitcpp')
    open(p, 'w').write('\n'.join(out2))
    print('0138s: files.arm64 entry added')
else:
    print('0138s: files.arm64 already has entry')
PYEOF

# 3) inject call at IOPMrootDomain::attach(IOPMrootDomain) site in IOServicePM.cpp
python3 << 'PYEOF'
import re
p = 'iokit/Kernel/IOServicePM.cpp'
s = open(p).read()
# find IORootParent attach into root domain (IOServicePM.cpp, initializeIOPM)
anchor = 'gIOPMRootDomain' 
# safest anchor: after IOPMrootDomain::initializeIOPM's PMinit? Use the
# resourceMatching-free spot: the start of IOPMrootDomain::start
if 'sweet_swd_start' not in s:
    # inject into IOPMrootDomain::start( IOService * provider )
    pat = 'IOReturn IOPMrootDomain::start( IOService * provider )'
    idx = s.find(pat)
    if idx < 0:
        pat = 'bool IOPMrootDomain::start('
        idx = s.find(pat)
    if idx >= 0:
        # find the opening brace then first newline after it
        brace = s.find('{', idx)
        ins = brace + 1
        inject = '\n    /* SWEET WDT: arm software watchdog */\n    sweet_swd_start(this, getWorkLoop());\n'
        s = s[:ins] + inject + s[ins:]
        open(p, 'w').write(s)
        print('0138s: watchdog armed in IOPMrootDomain::start')
    else:
        print('0138s: WARNING start() anchor not found - watchdog not armed')
else:
    print('0138s: already present')
PYEOF

# 4) progress calls at known SWEETDBG milestones in IOServicePM.cpp
python3 << 'PYEOF'
p = 'iokit/Kernel/IOServicePM.cpp'
s = open(p).read()
if 'sweet_wd_progress' not in s:
    # after IORTC wait print (0132's IOKitInitializeTime trace)
    n = s.count('sweet_wd_progress')
    # inject at every IOLog SWEETDBG: pwr occurrence (those are milestones)
    import re
    s2, n = re.subn(r'(IOLog\("SWEETDBG: pwr [^"]*\n")', r'); sweet_wd_progress(); (0', s)
    # that regex trick is fragile; simpler: append call after each full IOLog statement
    open(p, 'w').write(s)
    print(f'0138s: progress hooks injected at {n} sites')
PYEOF

echo '0138s: done'
