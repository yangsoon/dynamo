#!/bin/bash
# Stress test for router e2e tests
# Runs tests N times with fresh container per iteration
#
# Usage:
#   ./reproduce_flaky_test.sh -p <parallelism> [-s start] [-e end]
#
# Examples:
#   ./reproduce_flaky_test.sh -p serial              # iterations 1-100, serial
#   ./reproduce_flaky_test.sh -p serial -e 50        # iterations 1-50, serial
#   ./reproduce_flaky_test.sh -p 4                   # iterations 1-100, -n 4
#   ./reproduce_flaky_test.sh -p 4 -s 25 -e 100      # iterations 25-100, -n 4 (resume)
#   ./reproduce_flaky_test.sh -p 16 -s 1 -e 50       # iterations 1-50, -n 16

# Don't use set -e - we want to continue on test failures

usage() {
    echo "Usage: $0 -p <parallelism> [-s start] [-e end]"
    echo ""
    echo "Required:"
    echo "  -p, --parallelism   'serial' or a number (e.g., 1, 4, 16, 32)"
    echo ""
    echo "Optional:"
    echo "  -s, --start         Start iteration (default: 1)"
    echo "  -e, --end           End iteration (default: 100)"
    echo "  -h, --help          Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -p serial              # iterations 1-100, serial"
    echo "  $0 -p 4                   # iterations 1-100, -n 4"
    echo "  $0 -p 4 -s 25             # iterations 25-100, -n 4 (resume)"
    echo "  $0 -p 16 -s 1 -e 50       # iterations 1-50, -n 16"
    exit 1
}

# Default values
PARALLELISM=""
START=1
END=100

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--parallelism)
            PARALLELISM="$2"
            shift 2
            ;;
        -s|--start)
            START="$2"
            shift 2
            ;;
        -e|--end)
            END="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
    esac
done

# Validate parallelism argument
if [ -z "$PARALLELISM" ]; then
    echo "ERROR: Missing required argument: -p <parallelism>"
    echo ""
    usage
fi

if [ "$PARALLELISM" != "serial" ] && ! [[ "$PARALLELISM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid parallelism '$PARALLELISM' - must be 'serial' or a number"
    exit 1
fi

# Validate start/end
if ! [[ "$START" =~ ^[0-9]+$ ]] || ! [[ "$END" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Start and end must be numbers"
    exit 1
fi

if [ "$START" -gt "$END" ]; then
    echo "ERROR: Start ($START) cannot be greater than end ($END)"
    exit 1
fi

# Get HF_TOKEN
if [ -z "$HF_TOKEN" ] && [ -f ~/.cache/huggingface/token ]; then
    export HF_TOKEN=$(cat ~/.cache/huggingface/token)
fi

if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: HF_TOKEN not set and ~/.cache/huggingface/token not found"
    exit 1
fi

# Determine log directory and pytest args
if [ "$PARALLELISM" = "serial" ]; then
    LOG_DIR="logs/serial"
    PYTEST_ARGS=""
    LABEL="serial"
else
    LOG_DIR="logs/n${PARALLELISM}"
    PYTEST_ARGS="-n ${PARALLELISM}"
    LABEL="-n ${PARALLELISM}"
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Only clear logs if starting from 1
if [ "$START" -eq 1 ]; then
    rm -f "$LOG_DIR"/iter_*.log "$LOG_DIR"/results.txt "$LOG_DIR"/summary.txt
fi

TOTAL=$((END - START + 1))

echo "================================================================================"
echo "Stress Test: iterations $START-$END ($TOTAL runs), $LABEL"
echo "================================================================================"
echo "Log directory: $LOG_DIR"
echo "Started: $(date)"
echo "================================================================================"
echo ""

# Run iterations
for i in $(seq $START $END); do
    echo ""
    echo "================================================================================"
    echo "=== Iteration $i/$END - $(date) ==="
    echo "================================================================================"

    # Run test in fresh container with isolated bridge network
    # DYN_TEST_OUTPUT_PATH tells tests (conftest.py logger + ManagedProcess) where to write logs
    # Include iteration number so each run's test outputs are preserved: logs/n1/run001/test_*/
    RUN_NUM=$(printf "%03d" $i)
    docker run --rm --network bridge --shm-size=10G \
        --ulimit memlock=-1 --ulimit stack=67108864 --ulimit nofile=65536:65536 \
        -e HF_TOKEN="$HF_TOKEN" \
        -e DYN_TEST_OUTPUT_PATH="/workspace/$LOG_DIR/run${RUN_NUM}" \
        -v "$(pwd):/workspace" \
        -v "$HOME/.cache:/root/.cache" \
        -w /workspace \
        dynamo:latest-dev \
        bash -c "pytest tests/router/test_router_e2e_with_mockers.py $PYTEST_ARGS --basetemp=/tmp/pytest --durations=0 2>&1 | tee $LOG_DIR/iter_${i}.log; exit \${PIPESTATUS[0]}"

    EXIT_CODE=$?

    # Record result
    if [ $EXIT_CODE -ne 0 ]; then
        echo "FAILED" >> "$LOG_DIR/results.txt"
        echo "iter_$i: FAILED (exit $EXIT_CODE)" >> "$LOG_DIR/summary.txt"
    else
        echo "PASSED" >> "$LOG_DIR/results.txt"
        echo "iter_$i: PASSED" >> "$LOG_DIR/summary.txt"
    fi

    # Progress update every 10 iterations
    if [ $((i % 10)) -eq 0 ]; then
        PASSED=$(grep -c "PASSED" "$LOG_DIR/results.txt" 2>/dev/null || echo 0)
        FAILED=$(grep -c "FAILED" "$LOG_DIR/results.txt" 2>/dev/null || echo 0)
        echo ""
        echo ">>> Progress: $i/$END | Passed: $PASSED | Failed: $FAILED"
        echo ""
    fi
done

# Final summary
echo ""
echo "================================================================================"
echo "FINAL RESULTS"
echo "================================================================================"
PASSED=$(grep -c "PASSED" "$LOG_DIR/results.txt" 2>/dev/null || echo 0)
FAILED=$(grep -c "FAILED" "$LOG_DIR/results.txt" 2>/dev/null || echo 0)
TOTAL_RESULTS=$((PASSED + FAILED))
echo "Range: $START-$END ($TOTAL runs this session)"
echo "Total results: $TOTAL_RESULTS"
if [ "$TOTAL_RESULTS" -gt 0 ]; then
    echo "Passed: $PASSED ($(( PASSED * 100 / TOTAL_RESULTS ))%)"
    echo "Failed: $FAILED ($(( FAILED * 100 / TOTAL_RESULTS ))%)"
fi
echo ""
echo "=== Failed iterations ==="
grep "FAILED" "$LOG_DIR/summary.txt" 2>/dev/null || echo "None"
echo ""
echo "=== Error breakdown ==="
grep -h "FAILED" "$LOG_DIR"/iter_*.log 2>/dev/null | sort | uniq -c | sort -rn || echo "None"
echo ""
echo "Completed: $(date)"
echo "Logs: $LOG_DIR/"
echo "================================================================================"
