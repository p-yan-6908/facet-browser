#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -swift-version 5 -O -o build/blocktest tools/blocktest.swift
exec ./build/blocktest Resources/blocked-domains.txt
