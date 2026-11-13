#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

harness=$1
root=$2
size=$3
scale=$4
seed=$5
flight_time=$6
warmup=$7
samples=$8
baseline_samples=$9
interval=${10}

for value in "$samples" "$baseline_samples" "$interval"; do
    if [[ "$value" != <-> ]] || (( value < 1 )); then
        print -u2 'sample counts and interval must be positive integers'
        exit 1
    fi
done
duration=$(awk -v n="$samples" -v i="$interval" 'BEGIN { print n * i / 1000 }')
sudo -v
mkdir -p "$root"
output=$(mktemp -d "$root/$(date +%Y%m%d-%H%M%S)-XXXXXX")
harness_pid=''
sampler_pid=''
cleanup() {
    if [[ -n "$sampler_pid" ]]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
    fi
    if [[ -n "$harness_pid" ]]; then
        kill "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
    date -u
    sw_vers
    sysctl -n hw.model hw.memsize
    git rev-parse HEAD
    shasum -a 256 Sources/Saver/* Sources/Harness/* Scripts/profile* Makefile
    shasum -a 256 "$harness"
} > "$output/settings.txt"
print "Results: $output"
print "Measuring idle baseline ($baseline_samples samples)..."
sudo -n powermetrics --samplers cpu_power,gpu_power -i "$interval" -n "$baseline_samples" \
    > "$output/baseline.txt" 2> "$output/baseline-errors.txt"

print "Warming the renderer for $warmup seconds..."
"$harness" --profile "$output" --duration "$duration" --warmup "$warmup" \
    --time "$flight_time" --size "$size" --scale "$scale" --seed "$seed" \
    > "$output/harness.txt" 2>&1 &
harness_pid=$!
startup_timeout=$(awk -v warmup="$warmup" 'BEGIN { printf "%.0f", warmup + 120 }')
startup_deadline=$(( SECONDS + startup_timeout ))
while [[ ! -f "$output/ready" ]]; do
    if ! kill -0 "$harness_pid" 2>/dev/null; then
        cat "$output/harness.txt" >&2
        wait "$harness_pid"
        exit 1
    fi
    if (( SECONDS > startup_deadline )); then
        print -u2 "renderer startup timed out; see $output/harness.txt"
        exit 1
    fi
    sleep 0.1
done

print "Measuring rendering power ($samples samples, $duration seconds)..."
sudo -n powermetrics --samplers cpu_power,gpu_power -i "$interval" -n "$samples" \
    > "$output/power.txt" 2> "$output/power-errors.txt" &
sampler_pid=$!
touch "$output/start"
if ! wait "$sampler_pid"; then
    sampler_pid=''
    cat "$output/power-errors.txt" >&2
    exit 1
fi
sampler_pid=''
if ! wait "$harness_pid"; then
    harness_pid=''
    cat "$output/harness.txt" >&2
    exit 1
fi
harness_pid=''
awk -v baselineSamples="$baseline_samples" -v profileSamples="$samples" \
    -f Scripts/profile-summary.awk "$output/baseline.txt" "$output/power.txt" |
    tee "$output/summary.txt"
cat "$output/rendering.txt"
print "Complete. Results: $output"
