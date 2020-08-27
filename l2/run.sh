#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -ex

# Launch the hwlat tracer
echo hwlat > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on

# and report its results into infinity
cat /sys/kernel/debug/tracing/trace_pipe &
exec bash -i
