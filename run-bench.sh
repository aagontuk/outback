#!/bin/bash

# Benchmark sweep: run server + client for threads 1..64
# Server runs locally; client runs on node1 via SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="$SCRIPT_DIR/build/benchs/outback/server"
CLIENT_BIN="/proj/sandstorm-PG0/ashfaq/outback/build/benchs/outback/client"
CLIENT_NODE="node-1"
LOG_DIR="$SCRIPT_DIR/results"
CSV_FILE="$LOG_DIR/throughput.csv"
NUM_THREADS=64
mkdir -p "$LOG_DIR"

# Write CSV header
echo "threads,throughput_ops_per_sec" > "$CSV_FILE"

SERVER_ARGS="--seconds=600 --nkeys=64000000 --mem_threads=1 --workloads=ycsbb"
CLIENT_ARGS_COMMON="--nic_idx=2 --server_addr=10.10.2.1:8888 --seconds=30 --nkeys=64000000 --bench_nkeys=10000000 --coros=2 --mem_threads=1 --workloads=ycsbb"

SERVER_READY_WAIT=5   # seconds to wait after launching server before starting client
MAX_RETRIES=3         # max attempts per iteration before giving up
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "[bench] killing server (pid $SERVER_PID)"
        sudo kill "$SERVER_PID" 2>/dev/null || true
    fi
    # Kill any remaining server processes by binary path (sudo/taskset
    # exits immediately, leaving the server as an orphan not tracked by $!)
    sudo pkill -e -f "$SERVER_BIN" 2>/dev/null || true
    # Kill anything still holding port 8888 (ctrl daemon port)
    sudo lsof -ti :8888 2>/dev/null | xargs -r sudo kill -9 2>/dev/null || true
    # Wait until port 8888 is fully released before returning
    for _i in $(seq 1 30); do
        sudo lsof -i :8888 >/dev/null 2>&1 || break
        sleep 1
    done
    SERVER_PID=""
}
trap cleanup EXIT INT TERM

for threads in $(seq 1 ${NUM_THREADS}); do
    echo "========================================"
    echo "[bench] iteration: threads=$threads"
    echo "========================================"

    # CPU affinity for client: pin to cores 0..(threads-1)
    if [ "$threads" -eq 1 ]; then
        CLIENT_CORES="0"
    else
        CLIENT_CORES="0-$((threads - 1))"
    fi

    tput_val=""
    for attempt in $(seq 1 $MAX_RETRIES); do
        [ "$attempt" -gt 1 ] && echo "[bench] retrying (attempt $attempt/$MAX_RETRIES)..."

        # Kill any leftover server from a previous iteration or failed attempt
        cleanup

        SERVER_LOG="$LOG_DIR/server_t${threads}_attempt${attempt}.log"
        CLIENT_LOG="$LOG_DIR/client_t${threads}_attempt${attempt}.log"

        # Start server in background
        echo "[bench] starting server..."
        sudo taskset -c 32 "$SERVER_BIN" $SERVER_ARGS >"$SERVER_LOG" 2>&1 &

        sleep "$SERVER_READY_WAIT"

        # sudo/taskset exit immediately after forking the server, so $! is stale.
        # Use pgrep to find the actual server process.
        SERVER_PID=$(pgrep -f "$SERVER_BIN" | head -1)
        if [ -z "$SERVER_PID" ]; then
            echo "[bench] ERROR: server exited early, check $SERVER_LOG"
            continue
        fi
        echo "[bench] server pid=$SERVER_PID, log=$SERVER_LOG"

        # Run client on node1 via SSH
        echo "[bench] running client on $CLIENT_NODE with --threads=$threads (cores $CLIENT_CORES)..."
        if ssh "$CLIENT_NODE" \
               "sudo taskset -c $CLIENT_CORES $CLIENT_BIN $CLIENT_ARGS_COMMON --threads=$threads" \
               | tee "$CLIENT_LOG"; then
            echo "[bench] client done, stopping server..."
            cleanup

            tput_val=$(grep "\[micro\] Throughput(op/s):" "$CLIENT_LOG" | tail -1 | grep -oE '[0-9]+$')
            if [ -n "$tput_val" ]; then
                break   # success — exit retry loop
            fi
            echo "[bench] WARNING: could not parse throughput, retrying..."
        else
            echo "[bench] WARNING: client failed (exit $?), check $CLIENT_LOG"
            cleanup
        fi
    done

    # Record result (N/A if all attempts failed)
    if [ -n "$tput_val" ]; then
        echo "$threads,$tput_val" >> "$CSV_FILE"
        echo "[bench] threads=$threads throughput=$tput_val ops/s"
    else
        echo "$threads,N/A" >> "$CSV_FILE"
        echo "[bench] ERROR: all $MAX_RETRIES attempts failed for threads=$threads"
    fi
    echo ""
done

echo "[bench] all iterations complete. results in $LOG_DIR/"
echo "[bench] CSV summary: $CSV_FILE"
