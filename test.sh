#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc Sources/Probe.swift Tests/ProbeTests.swift -o .build/probe-tests
.build/probe-tests
xcrun swiftc Sources/Probe.swift Sources/Policies.swift Tests/PolicyTests.swift -o .build/policy-tests
.build/policy-tests
