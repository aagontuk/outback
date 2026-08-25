#!/usr/bin/env python3
"""Plot throughput scaling vs. client thread count for YCSB workloads A/B/C
under uniform and zipfian key distributions.

Usage:
    python3 scripts/plot_scaling.py [--csv PATH] [--out PATH]
"""

import argparse
import csv
from collections import defaultdict

import matplotlib.pyplot as plt

# Okabe-Ito palette (colorblind-safe), one color per server-thread count.
THREAD_COLORS = {
    1: "#E69F00",
    2: "#56B4E9",
    3: "#009E73",
    4: "#F0E442",
    5: "#0072B2",
    6: "#D55E00",
    7: "#CC79A7",
    8: "#000000",
}

WORKLOADS = ["ycsba", "ycsbb", "ycsbc"]
WORKLOAD_LABELS = {"ycsba": "YCSB-A", "ycsbb": "YCSB-B", "ycsbc": "YCSB-C"}
DISTS = ["uniform", "zipfian"]
DIST_LABELS = {"uniform": "Uniform", "zipfian": "Zipfian"}


def load_data(csv_path):
    # data[(dist, workload, threads)] -> list of (client_threads, throughput)
    data = defaultdict(list)
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            threads = int(row["threads"])
            client_threads = int(row["client_threads"])
            workload = row["workload"]
            dist = row["dist"]
            throughput = float(row["throughput_ops_per_sec"])
            data[(dist, workload, threads)].append((client_threads, throughput))
    for key in data:
        data[key].sort()
    return data


def plot(data, out_path):
    fig, axes = plt.subplots(
        2, 3, figsize=(15, 8), sharex=True, sharey=True, constrained_layout=True
    )

    thread_counts = sorted({t for (_, _, t) in data})

    for row, dist in enumerate(DISTS):
        for col, workload in enumerate(WORKLOADS):
            ax = axes[row][col]
            for threads in thread_counts:
                points = data.get((dist, workload, threads))
                if not points:
                    continue
                x = [p[0] for p in points]
                y = [p[1] / 1e6 for p in points]
                ax.plot(
                    x,
                    y,
                    color=THREAD_COLORS.get(threads, "#999999"),
                    linewidth=2,
                    marker="o",
                    markersize=5,
                    label=f"{threads} server threads",
                )
            ax.set_title(f"{WORKLOAD_LABELS[workload]} ({DIST_LABELS[dist]})")
            ax.grid(True, linewidth=0.5, alpha=0.3)
            if row == 1:
                ax.set_xlabel("Client threads")
            if col == 0:
                ax.set_ylabel("Throughput (Mop/s)")

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(
        handles,
        labels,
        loc="lower center",
        ncol=len(thread_counts),
        bbox_to_anchor=(0.5, -0.06),
        frameon=False,
    )

    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"Wrote {out_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--csv",
        default="results/scaling_latest/throughput.csv",
        help="Path to throughput CSV file",
    )
    parser.add_argument(
        "--out",
        default="results/scaling_latest/throughput_scaling.png",
        help="Path to write the output plot",
    )
    args = parser.parse_args()

    data = load_data(args.csv)
    plot(data, args.out)


if __name__ == "__main__":
    main()
