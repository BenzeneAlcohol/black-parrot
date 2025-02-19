#!/bin/bash

# Command line arguments
if [ "$ne" == '1' ]
then
  echo "Usage: $0 <verilator, vcs>"
  exit 1
elif [ $1 == "vcs" ]
then
    SUFFIX=v
elif [ $1 == "verilator" ]
then
    SUFFIX=sc
else
  echo "Usage: $0 <verilator, vcs>"
  exit 1
fi

# Bash array to iterate over for coherence protocols for ucode CCE tests
protos=(
    "ei"
    "msi"
    "mesi"
    "msi-nonspec"
    "mesi-nonspec"
    "moesif"
    )

# The base command to append the configuration to
cmd_base="make -C bp_me/syn run_testlist.${SUFFIX}"

# Any setup needed for the job
make -C bp_me/syn clean

let JOBS=${#protos[@]}

# Run the regression in parallel on each configuration
echo "Running ${JOBS} jobs with 1 core per job"

# ucode CCE (EI, MSI, MESI, MSI-nonspec, MESI-nonspec)
parallel --jobs ${JOBS} --results regress_logs --progress "$cmd_base COH_PROTO={} CFG=e_bp_test_multicore_half_cce_ucode_cfg" ::: ${protos[@]}
# FSM CCE (MOESIF)
parallel --jobs ${JOBS} --results regress_logs --progress "$cmd_base CFG={}" ::: e_bp_test_multicore_half_cfg

# Check for failures in the report directory
grep -cr "FAIL" bp_me/syn/reports/ && echo "[CI CHECK] $0: FAILED" && exit 1
echo "[CI CHECK] $0: PASSED" && exit 0
