FNR == 1 { phase++ }
/^CPU Power:/ { cpu = power($3, $4); haveCPU = 1; haveGPU = 0 }
/^GPU Power:/ && haveCPU && !haveGPU { gpu = power($3, $4); haveGPU = 1 }
/^Combined Power/ {
    if (!haveCPU || !haveGPU || $NF != "mW") {
        print "invalid power sample in " FILENAME > "/dev/stderr"
        failed = 1
        exit 1
    }
    count[phase]++
    totalCPU[phase] += cpu
    totalGPU[phase] += gpu
    totalCombined[phase] += power($(NF - 1), $NF)
    haveCPU = haveGPU = 0
}
END {
    if (failed) exit 1
    if (count[1] != baselineSamples || count[2] != profileSamples) {
        print "incomplete power samples; inspect the raw logs" > "/dev/stderr"
        exit 1
    }
    printf "%-12s %12s %12s %12s\n", "power (W)", "baseline", "rendering", "increase"
    row("CPU", totalCPU[1], totalCPU[2])
    row("GPU", totalGPU[1], totalGPU[2])
    row("Combined", totalCombined[1], totalCombined[2])
}
function power(value, unit) {
    if (unit != "mW" || value !~ /^[0-9]+([.][0-9]+)?$/) {
        print "invalid power reading in " FILENAME > "/dev/stderr"
        failed = 1
        exit 1
    }
    return value + 0
}
function row(label, idle, active, baseline, rendering) {
    baseline = idle / count[1] / 1000
    rendering = active / count[2] / 1000
    printf "%-12s %12.3f %12.3f %12.3f\n", label, baseline, rendering, rendering - baseline
}
