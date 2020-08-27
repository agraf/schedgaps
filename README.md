## Core Scheduling Gap Benchmark

Co- and core scheduling have been under discussion since ~2018 and most
people have been concerned with getting a solution that works at all
upstream.

Unfortunately, during some preliminary tests, all of these approaches
have shown significant fairness issues. These usually manifest in long
starvation periods for threads.

#### What can I benchmark?

This repository looks at the process view of such starvation. It allows
us to trace scheduler operations while an application that does bursty
operations is running. The combination of sleeping and heavy work is
what has previously been rarely benchmarked for.

The repository contains two test targets: kvm and user.

##### kvm

This target simulates a virtual machine environment. It spawns a VM
with 4 threads. Inside this VM, it spawns 8 VMs with 2 threads each,
all pinned to the same virtual L1 core.

Inside the L2 VMs, it launches the Linux [Hardware Latency Tracer](https://www.kernel.org/doc/html/latest/trace/hwlat_detector.html)
which runs a busy loop of rdtsc to find execution gaps for 0.5s, then
goes idle, then does the busy loop on one of the two threads again, etc.

The output of this target is the Linux hwlat tracer output of one of the
VMs running and will look like the following:

    <...>-105   [001] d...     3.630702: #1     inner/outer(us): 32522/48575 ts:1598486359.129995457
    <...>-105   [000] d...     4.798208: #2     inner/outer(us): 35568/52434 ts:1598486360.298155993
    <...>-105   [001] d...     5.833050: #3     inner/outer(us): 77049/37218 ts:1598486361.364877905
    <...>-105   [000] d...     6.892944: #4     inner/outer(us): 65977/62870 ts:1598486362.389955284
    <...>-105   [001] d...     7.916369: #5     inner/outer(us): 54781/72022 ts:1598486363.450472521

##### user (default)

The user target simulates the same behavior of the Linux Hardware Latency
Tracer inside of virtual machines, but in a tiny user space application.
This means that for benchmarking, we do not need to go through the heavy
lifting of nested virtualization.

It also differentiates in behavoir slightly, as it exits as soon as it
finds an execution gap that it considers too long (currently set to 100ms).
When that happens, it will provide an output like this:

    Max latency: 47 ms (119754120 ticks, 16 online)
    Max latency: 79 ms (200011176 ticks, 16 online)
    Max latency: 76 ms (192096900 ticks, 16 online)
    diff: 130ms

It then writes a trace marker to ftrace and dumps the current ftrace buffer
to /dev/shm/log on the host environment.

With that mechanism, it's relatively easy to see why a big execution gap was
happening and it allows quick experimentation with remedies.

#### How do I use this?

First, you need to build the initrds for L1 and L2 guests.

`$ make`

Then, you build a kernel with either Co- or Core-Scheduling patches included
and enabled. Once ready, you can start the user benchmark

`$ ./qemu_run <bzImage>`

or if you want to run the "kvm" target, you run

`$ ./qemu_run <bzImage> kvm`

#### Something does not work the way I want it

Feel free to reach out to create a github issue or even better, send a pull
request with a fix :).
