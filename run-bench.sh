#!/bin/bash

# Benchmark sweep: run server + client across workloads, distributions,
# server thread counts, and client thread counts.
# Server runs locally; client threads are spread across multiple client
# nodes (node-1..node-4) via SSH, THREADS_PER_NODE threads per node. E.g.
# with THREADS_PER_NODE=32 and --threads=128, node-1 gets threads 1-32,
# node-2 gets 33-64, node-3 gets 65-96, node-4 gets 97-128.

set -euo pipefail

usage() {
    echo "Usage: $0 --min-server-threads=N --max-server-threads=N [options]"
    echo ""
    echo "Required:"
    echo "  --min-server-threads=N   Minimum number of server mem_threads"
    echo "  --max-server-threads=N   Maximum number of server mem_threads"
    echo ""
    echo "Optional:"
    echo "  --min-client-threads=N   Minimum number of client threads (default: 1)"
    echo "  --max-client-threads=N   Maximum number of client threads (default: 128)"
    echo "  --client-threads=A,B,C  Comma-separated list of client thread counts to run"
    echo "                           (e.g. 8,16,32,64) instead of sweeping min..max"
    echo "  --client-nodes=A,B,C     Comma-separated list of client nodes to use"
    echo "                           (default: node-1,node-2,node-3,node-4)"
    echo "  --client-nic-idx=A,B,C,D Comma-separated nic_idx per client node, in the same"
    echo "                           order as node-1,node-2,node-3,node-4 (default: 0 for all)"
    echo "  --server-nic-idx=N       nic_idx the server binds its RDMA QPs to (default: 0)"
    echo "  --numa-node=N            Pin server and client processes to NUMA node N via"
    echo "                           numactl (cpunodebind+membind), instead of plain taskset"
    echo "  --server-timeout=N       Server --seconds value; actual server lifetime is N+10"
    echo "                           seconds (default: 600)"
    echo "  --client-timeout=N       Max seconds to wait for a client on a node to finish"
    echo "                           before treating it as hung and retrying (default: 650)"
    echo "  --results-dir=PATH       Results directory (default: <script_dir>/results/outback_<timestamp>)"
    echo "  --resume                 Append to the existing CSV in --results-dir instead of"
    echo "                           creating a new one (requires --results-dir)"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="$SCRIPT_DIR/build/benchs/outback/server"
CLIENT_BIN="/proj/sandstorm-PG0/ashfaq/outback/build/benchs/outback/client"
CLIENT_NODES=(node-1 node-2 node-3 node-4)
THREADS_PER_NODE=32
MIN_CLIENT_THREADS=1
MAX_CLIENT_THREADS=128
CLIENT_THREADS_LIST=""
CLIENT_NODES_LIST=""
CLIENT_NIC_IDX_LIST=""
SERVER_NIC_IDX=0
NUMA_NODE=""
SERVER_TIMEOUT=600
CLIENT_TIMEOUT=650
# WORKLOADS="ycsba ycsbb ycsbc"
WORKLOADS="ycsba"
# DISTS="uniform zipfian"
# DISTS="uniform"
DISTS="zipfian"
SERVER_CORE_START=0  # first core pinned to server; expands to cover all server threads (server and client run on separate nodes, so no offset is needed; cores 32-63 are offline on this hardware)
MIN_SERVER_THREADS=""
MAX_SERVER_THREADS=""
LOG_DIR=""
RESUME=""

for arg in "$@"; do
    case "$arg" in
        --min-server-threads=*) MIN_SERVER_THREADS="${arg#*=}" ;;
        --max-server-threads=*) MAX_SERVER_THREADS="${arg#*=}" ;;
        --min-client-threads=*) MIN_CLIENT_THREADS="${arg#*=}" ;;
        --max-client-threads=*) MAX_CLIENT_THREADS="${arg#*=}" ;;
        --client-threads=*)     CLIENT_THREADS_LIST="${arg#*=}" ;;
        --client-nodes=*)       CLIENT_NODES_LIST="${arg#*=}" ;;
        --client-nic-idx=*)     CLIENT_NIC_IDX_LIST="${arg#*=}" ;;
        --server-nic-idx=*)     SERVER_NIC_IDX="${arg#*=}" ;;
        --numa-node=*)          NUMA_NODE="${arg#*=}" ;;
        --server-timeout=*)     SERVER_TIMEOUT="${arg#*=}" ;;
        --client-timeout=*)     CLIENT_TIMEOUT="${arg#*=}" ;;
        --results-dir=*)        LOG_DIR="${arg#*=}" ;;
        --resume)               RESUME=1 ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

[ -z "$MIN_SERVER_THREADS" ] && { echo "Error: --min-server-threads is required"; usage; }
[ -z "$MAX_SERVER_THREADS" ] && { echo "Error: --max-server-threads is required"; usage; }
[ -n "$RESUME" ] && [ -z "$LOG_DIR" ] && { echo "Error: --resume requires --results-dir"; usage; }
[ -z "$LOG_DIR" ] && LOG_DIR="$SCRIPT_DIR/results/outback_$(date +%Y%m%d_%H%M%S)"

# Override the default client node list if requested
if [ -n "$CLIENT_NODES_LIST" ]; then
    CLIENT_NODES=(${CLIENT_NODES_LIST//,/ })
fi

# List of client thread counts to sweep over
if [ -n "$CLIENT_THREADS_LIST" ]; then
    CLIENT_THREADS_VALUES=(${CLIENT_THREADS_LIST//,/ })
else
    CLIENT_THREADS_VALUES=($(seq ${MIN_CLIENT_THREADS} ${MAX_CLIENT_THREADS}))
fi

# Per-node nic_idx, in the same order as CLIENT_NODES (default: 0 for every node)
if [ -n "$CLIENT_NIC_IDX_LIST" ]; then
    CLIENT_NIC_IDX=(${CLIENT_NIC_IDX_LIST//,/ })
    if [ "${#CLIENT_NIC_IDX[@]}" -ne "${#CLIENT_NODES[@]}" ]; then
        echo "Error: --client-nic-idx must list exactly ${#CLIENT_NODES[@]} values (one per client node), got ${#CLIENT_NIC_IDX[@]}"
        usage
    fi
else
    CLIENT_NIC_IDX=()
    for _node in "${CLIENT_NODES[@]}"; do CLIENT_NIC_IDX+=(0); done
fi

# Builds the core-pinning command prefix for a given core range: plain
# taskset by default, or numactl (cpunodebind+membind to --numa-node, with
# --physcpubind restricting to the given cores) when --numa-node is set.
pin_cmd() {
    local cores="$1"
    if [ -n "$NUMA_NODE" ]; then
        echo "numactl --cpunodebind=$NUMA_NODE --membind=$NUMA_NODE --physcpubind=$cores"
    else
        echo "taskset -c $cores"
    fi
}

# If --numa-node is set, make sure numactl is present locally (server) and
# on every client node, installing it via apt where it's missing.
ensure_numactl() {
    [ -z "$NUMA_NODE" ] && return

    echo "[bench] checking numactl is installed (--numa-node=$NUMA_NODE)..."

    if ! command -v numactl >/dev/null 2>&1; then
        echo "[bench] numactl not found locally, installing..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y numactl
    fi

    local pids=()
    for node in "${CLIENT_NODES[@]}"; do
        ssh "$node" '
            if ! command -v numactl >/dev/null 2>&1; then
                echo "[bench] numactl not found on '"$node"', installing..."
                sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y numactl
            fi
        ' &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || { echo "[bench] ERROR: failed to ensure numactl is installed on a client node"; exit 1; }
    done

    echo "[bench] numactl check complete."
}
ensure_numactl

# Expands a Linux cpulist string like "0-3,8,10-11" into a space-separated
# list of individual CPU numbers.
expand_cpulist() {
    local list="$1" part start end
    local out=()
    IFS=',' read -ra parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"
            end="${part#*-}"
            for ((c = start; c <= end; c++)); do out+=("$c"); done
        else
            out+=("$part")
        fi
    done
    echo "${out[@]}"
}

# Reads the CPU list belonging to NUMA node $NUMA_NODE straight from
# /sys/devices/system/node, on the local host if $1 is empty, otherwise over
# SSH on host $1. This is what guarantees the cores we pin to actually
# belong to the requested NUMA node, instead of assuming core numbers
# 0..N-1 happen to live on that node.
numa_node_cpus() {
    local host="$1" cpulist
    if [ -z "$host" ]; then
        cpulist=$(cat "/sys/devices/system/node/node${NUMA_NODE}/cpulist" 2>/dev/null) || true
    else
        cpulist=$(ssh "$host" "cat /sys/devices/system/node/node${NUMA_NODE}/cpulist" 2>/dev/null) || true
    fi
    if [ -z "$cpulist" ]; then
        echo "[bench] ERROR: could not read CPU list for NUMA node $NUMA_NODE on ${host:-local host} (check /sys/devices/system/node/ for valid node numbers)" >&2
        exit 1
    fi
    expand_cpulist "$cpulist"
}

# Picks the first $1 CPUs out of the space-separated CPU list in $2 and
# returns them as a comma-separated string (valid for both taskset -c and
# numactl --physcpubind). Errors out if the NUMA node doesn't have enough.
cores_from_numa() {
    local n="$1"
    local -a cpus=($2)
    if [ "$n" -gt "${#cpus[@]}" ]; then
        echo "[bench] ERROR: requested $n threads but NUMA node $NUMA_NODE only has ${#cpus[@]} CPUs available" >&2
        exit 1
    fi
    local -a sel=("${cpus[@]:0:$n}")
    local IFS=,
    echo "${sel[*]}"
}

# Precompute the NUMA node's CPU list once for the local (server) host and
# every client node, so per-iteration core selection never has to guess.
if [ -n "$NUMA_NODE" ]; then
    SERVER_NUMA_CPUS="$(numa_node_cpus "")"
    echo "[bench] NUMA node $NUMA_NODE CPUs (local/server): $SERVER_NUMA_CPUS"

    CLIENT_NUMA_CPUS=()   # CLIENT_NUMA_CPUS[i] = CPU list string for CLIENT_NODES[i]
    for node in "${CLIENT_NODES[@]}"; do
        node_cpus="$(numa_node_cpus "$node")"
        echo "[bench] NUMA node $NUMA_NODE CPUs on $node: $node_cpus"
        CLIENT_NUMA_CPUS+=("$node_cpus")
    done
fi

CSV_FILE="$LOG_DIR/throughput.csv"
mkdir -p "$LOG_DIR"

if [ -n "$RESUME" ] && [ -f "$CSV_FILE" ]; then
    echo "[bench] --resume: appending to existing $CSV_FILE"
else
    # Write CSV header (fresh run, or --resume with no prior CSV to resume from)
    echo "threads,client_threads,workload,dist,throughput_ops_per_sec" > "$CSV_FILE"
fi

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

    # Kill any leftover client processes on all client nodes (best effort, in parallel)
    for node in "${CLIENT_NODES[@]}"; do
        ssh "$node" "sudo pkill -f $CLIENT_BIN" 2>/dev/null &
    done
    wait 2>/dev/null || true
}

# On Ctrl-C/SIGTERM: kill the server and every client node, then actually
# exit. (Without this, cleanup() alone would run and the script would just
# continue on to the next loop iteration and re-launch everything.)
handle_signal() {
    local sig="$1"
    trap - INT TERM   # a second Ctrl-C should kill us immediately, not loop through this again
    echo ""
    echo "[bench] caught $sig, killing server and all client processes on all nodes..."
    cleanup
    trap - EXIT       # avoid running cleanup twice via the EXIT trap below
    exit 130
}

trap cleanup EXIT
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

# Splits a total client thread count across CLIENT_NODES, THREADS_PER_NODE
# threads per node, filling node-1 first, then node-2, etc. Populates the
# global NODE_THREADS array (one entry per node in CLIENT_NODES, 0 if unused).
compute_node_threads() {
    local total=$1
    local remaining=$total
    NODE_THREADS=()
    for _node in "${CLIENT_NODES[@]}"; do
        if [ "$remaining" -le 0 ]; then
            NODE_THREADS+=(0)
            continue
        fi
        local n=$remaining
        [ "$n" -gt "$THREADS_PER_NODE" ] && n=$THREADS_PER_NODE
        NODE_THREADS+=("$n")
        remaining=$((remaining - n))
    done
    if [ "$remaining" -gt 0 ]; then
        echo "[bench] ERROR: --threads=$total exceeds capacity of ${#CLIENT_NODES[@]} nodes x ${THREADS_PER_NODE} threads/node"
        exit 1
    fi
}

for server_threads in $(seq ${MIN_SERVER_THREADS} ${MAX_SERVER_THREADS}); do
for workload in $WORKLOADS; do
for dist in $DISTS; do
    if [ -n "$NUMA_NODE" ]; then
        SERVER_CORES="$(cores_from_numa "$server_threads" "$SERVER_NUMA_CPUS")"
    elif [ "$server_threads" -eq 1 ]; then
        SERVER_CORES="$SERVER_CORE_START"
    else
        SERVER_CORES="$SERVER_CORE_START-$((SERVER_CORE_START + server_threads - 1))"
    fi

    # --seconds=$SERVER_TIMEOUT (server lifetime = FLAGS_seconds+10, see
    # server.cc) so the server comfortably outlives the client's own 64M-key
    # index build, which is single-threaded and can take well over 10
    # minutes; a server that exits before the client finishes connecting
    # leaves every client RPC waiting on a reply that will never come,
    # hanging pthread_join forever. --client-timeout bounds that hang instead
    # of leaving it to run forever (see the wait loop below).
    SERVER_ARGS="--seconds=${SERVER_TIMEOUT} --nkeys=64000000 --mem_threads=${server_threads} --workloads=${workload} --dists=${dist} --nic_idx=${SERVER_NIC_IDX}"
    CLIENT_ARGS_COMMON="--server_addr=10.10.1.1:8888 --seconds=30 --nkeys=64000000 --bench_nkeys=10000000 --coros=2 --mem_threads=${server_threads} --workloads=${workload} --dists=${dist}"

    echo "###################################################"
    echo "[bench] server_threads=$server_threads workload=$workload dist=$dist"
    echo "###################################################"

    for threads in "${CLIENT_THREADS_VALUES[@]}"; do
        echo "========================================"
        echo "[bench] iteration: server_threads=$server_threads workload=$workload dist=$dist threads=$threads"
        echo "========================================"

        # Split $threads client threads across CLIENT_NODES, THREADS_PER_NODE per node
        compute_node_threads "$threads"

        tput_val=""
        for attempt in $(seq 1 $MAX_RETRIES); do
            [ "$attempt" -gt 1 ] && echo "[bench] retrying (attempt $attempt/$MAX_RETRIES)..."

            # Kill any leftover server/client from a previous iteration or failed attempt
            cleanup

            SERVER_LOG="$LOG_DIR/server_st${server_threads}_${workload}_${dist}_t${threads}_attempt${attempt}.log"

            # Start server in background
            SERVER_PIN="$(pin_cmd "$SERVER_CORES")"
            echo "[bench] starting server (cores $SERVER_CORES, pin: $SERVER_PIN)..."
            sudo $SERVER_PIN "$SERVER_BIN" $SERVER_ARGS >"$SERVER_LOG" 2>&1 &

            sleep "$SERVER_READY_WAIT"

            # sudo/taskset exit immediately after forking the server, so $! is stale.
            # Use pgrep to find the actual server process.
            SERVER_PID=$(pgrep -f "$SERVER_BIN" | head -1)
            if [ -z "$SERVER_PID" ]; then
                echo "[bench] ERROR: server exited early, check $SERVER_LOG"
                continue
            fi
            echo "[bench] server pid=$SERVER_PID, log=$SERVER_LOG"

            # Launch one client per node in parallel, each pinned to cores
            # 0..(node_threads-1) on its own node, running its share of threads.
            CLIENT_PIDS=()
            CLIENT_LOGS=()
            CLIENT_NODES_USED=()
            for i in "${!CLIENT_NODES[@]}"; do
                node_threads="${NODE_THREADS[$i]}"
                [ "$node_threads" -eq 0 ] && continue
                node="${CLIENT_NODES[$i]}"

                if [ -n "$NUMA_NODE" ]; then
                    node_cores="$(cores_from_numa "$node_threads" "${CLIENT_NUMA_CPUS[$i]}")"
                elif [ "$node_threads" -eq 1 ]; then
                    node_cores="0"
                else
                    node_cores="0-$((node_threads - 1))"
                fi

                node_nic_idx="${CLIENT_NIC_IDX[$i]}"
                # Each client thread's UD session is registered on the server keyed
                # by start_threads+thread_id, which must be globally unique across
                # all client nodes (server assumes no id collisions). Since every
                # node numbers its local threads 0..node_threads-1, offset each
                # node by i*THREADS_PER_NODE so ids never collide across nodes.
                node_start_threads=$((i * THREADS_PER_NODE))
                node_pin="$(pin_cmd "$node_cores")"
                node_log="$LOG_DIR/client_st${server_threads}_${workload}_${dist}_t${threads}_attempt${attempt}_${node}.log"
                echo "[bench] running client on $node with --threads=$node_threads --nic_idx=$node_nic_idx --start_threads=$node_start_threads (cores $node_cores, pin: $node_pin, timeout: ${CLIENT_TIMEOUT}s)..."
                # timeout bounds a hung/stuck client (e.g. server already exited,
                # per the comment above) so a wedged iteration fails fast instead
                # of blocking the whole sweep forever; -k gives it 10s to die
                # cleanly before SIGKILL. This only kills the local ssh process —
                # cleanup() below still pkills the remote client binary on every
                # node to mop up anything left running server-side.
                timeout -k 10 "${CLIENT_TIMEOUT}s" ssh "$node" \
                    "sudo $node_pin $CLIENT_BIN $CLIENT_ARGS_COMMON --threads=$node_threads --nic_idx=$node_nic_idx --start_threads=$node_start_threads" \
                    >"$node_log" 2>&1 &

                CLIENT_PIDS+=("$!")
                CLIENT_LOGS+=("$node_log")
                CLIENT_NODES_USED+=("$node")
            done

            clients_ok=true
            for i in "${!CLIENT_PIDS[@]}"; do
                wait "${CLIENT_PIDS[$i]}" && wait_rc=0 || wait_rc=$?
                if [ "$wait_rc" -eq 124 ]; then
                    echo "[bench] WARNING: client on ${CLIENT_NODES_USED[$i]} timed out after ${CLIENT_TIMEOUT}s (hung?), check ${CLIENT_LOGS[$i]}"
                    clients_ok=false
                elif [ "$wait_rc" -ne 0 ]; then
                    echo "[bench] WARNING: client on ${CLIENT_NODES_USED[$i]} failed (exit $wait_rc), check ${CLIENT_LOGS[$i]}"
                    clients_ok=false
                fi
            done

            # Show client output for visibility, same as the old `tee` behavior
            for log in "${CLIENT_LOGS[@]}"; do
                cat "$log"
            done

            if $clients_ok; then
                echo "[bench] all clients done, stopping server..."
                cleanup

                # Total throughput is the sum of each node's reported throughput
                sum_tput=0
                parse_ok=true
                for log in "${CLIENT_LOGS[@]}"; do
                    node_tput=$(grep "\[micro\] Throughput(op/s):" "$log" | tail -1 | grep -oE '[0-9]+$')
                    if [ -z "$node_tput" ]; then
                        parse_ok=false
                        break
                    fi
                    sum_tput=$((sum_tput + node_tput))
                done

                if $parse_ok; then
                    tput_val="$sum_tput"
                    break   # success — exit retry loop
                fi
                echo "[bench] WARNING: could not parse throughput from one or more client logs, retrying..."
            else
                echo "[bench] WARNING: one or more clients failed, retrying..."
                cleanup
            fi
        done

        # Record result (N/A if all attempts failed)
        if [ -n "$tput_val" ]; then
            echo "$server_threads,$threads,$workload,$dist,$tput_val" >> "$CSV_FILE"
            echo "[bench] server_threads=$server_threads workload=$workload dist=$dist threads=$threads throughput=$tput_val ops/s"
        else
            echo "$server_threads,$threads,$workload,$dist,N/A" >> "$CSV_FILE"
            echo "[bench] ERROR: all $MAX_RETRIES attempts failed for server_threads=$server_threads workload=$workload dist=$dist threads=$threads"
        fi
        echo ""
    done

    echo "[bench] server_threads=$server_threads workload=$workload dist=$dist complete."
    echo ""
done
done
done

echo "[bench] all iterations complete. results in $LOG_DIR/"
echo "[bench] CSV summary: $CSV_FILE"
