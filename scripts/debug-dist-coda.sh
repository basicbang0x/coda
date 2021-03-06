#!/bin/bash

#
# ONLY USED FOR DEBUGGING
# Use this script to verify that dist builds build on other machines
#

# Change to whatever dist.zip you stick on s3
DIST_ZIP=""
BUCKET=""

curl "https://s3-us-west-2.amazonaws.com/$BUCKET/$DIST_ZIP" > "$DIST_ZIP"

unzip "$DIST_ZIP" -d dist

cd dist

system_profiler SPSoftwareDataType
sysctl -n machdep.cpu.brand_string

echo "========="
echo "== Verify static initilization works"
echo "========="
./coda.exe -help

# Re-enable if you want to debug illegal instructions
# lldb -o run ./coda.exe transaction-snark-profiler

echo "========="
echo "== Verify snarks work"
echo "========="
./coda.exe transaction-snark-profiler

rm -rf ~/.coda-config

echo "========="
echo "== Verify full test"
echo "========="
./coda.exe integration-tests full-test

