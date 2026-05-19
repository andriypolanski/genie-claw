#!/usr/bin/env bash
# M1 exit soak harness — 100 consecutive voice cycles (issue #109).
#
# Usage:
#   ./tests/voice/100-cycle-soak.sh run [--cycles N] [--config PATH]
#   ./tests/voice/100-cycle-soak.sh analyze LOG [--expect-cycles N] [--ledger PATH]
#
# `run` starts genie-core --voice and tees stderr to a timestamped log, then
# analyzes it. Complete N wake→STT→LLM→TTS cycles manually (push-to-talk Enter)
# or via wake-word before the analyzer runs.
#
# `analyze` parses a voice-loop log and emits pass/fail plus a JSON ledger.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"

DEFAULT_CYCLES=100
# Upper bound per cycle: record_secs (3) + STT + LLM + TTS + post-TTS silence.
MAX_CYCLE_MS=180000

usage() {
    cat <<'EOF'
Usage:
  100-cycle-soak.sh run   [--cycles N] [--config PATH] [--log PATH]
  100-cycle-soak.sh analyze LOG [--expect-cycles N] [--ledger PATH] [--max-cycle-ms MS]

Commands:
  run      Start genie-core --voice; log stderr; analyze when the process exits.
  analyze  Parse an existing voice-loop log and print pass/fail + JSON ledger.

Environment:
  GENIEPOD_CONFIG   Used when --config is omitted (run mode).
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required command not found: $1" >&2
        exit 1
    fi
}

timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

analyze_log() {
    local log_path=$1
    local expect_cycles=$2
    local ledger_path=$3
    local max_cycle_ms=$4

    if [[ ! -f "${log_path}" ]]; then
        echo "error: log file not found: ${log_path}" >&2
        exit 1
    fi

    mkdir -p "$(dirname "${ledger_path}")"

    require_cmd python3

    LOG_PATH="${log_path}" \
        LEDGER_PATH="${ledger_path}" \
        EXPECT_CYCLES="${expect_cycles}" \
        MAX_CYCLE_MS="${max_cycle_ms}" \
        python3 - <<'PY'
import json
import os
import re
import sys

log_path = os.environ["LOG_PATH"]
ledger_path = os.environ["LEDGER_PATH"]
expect = int(os.environ["EXPECT_CYCLES"])
max_ms = int(os.environ["MAX_CYCLE_MS"])

recording_re = re.compile(r"\[voice\] Recording ")
you_said_re = re.compile(r'\[voice\] You said: "([^"]*)"')
geniepod_re = re.compile(r"\[voice\] GeniePod:")
total_re = re.compile(r"\[voice\] Total cycle: (\d+) ms")
no_speech_re = re.compile(r"\[voice\] No speech detected\.")
fail_re = re.compile(r"\[voice\] (?:STT failed:|Recording failed:)")

in_cycle = False
saw_recording = False
saw_you_said = False
saw_geniepod = False
transcript = ""
cycles = []
failures = 0
silent_drops = 0
stalls = 0

with open(log_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if recording_re.search(line):
            if not in_cycle:
                in_cycle = True
                saw_recording = True
                saw_you_said = False
                saw_geniepod = False
                transcript = ""
            continue

        m = you_said_re.search(line)
        if m:
            saw_you_said = True
            transcript = m.group(1)
            continue

        if geniepod_re.search(line):
            saw_geniepod = True
            continue

        if in_cycle and no_speech_re.search(line) and saw_recording and not saw_you_said:
            failures += 1
            continue

        if in_cycle and fail_re.search(line):
            failures += 1
            continue

        m = total_re.search(line)
        if not m:
            continue

        total_ms = int(m.group(1))
        if in_cycle and saw_you_said and transcript and not saw_geniepod:
            silent_drops += 1
        if total_ms > max_ms:
            stalls += 1

        cycles.append(
            {
                "cycle": len(cycles) + 1,
                "total_ms": total_ms,
                "had_transcript": saw_you_said,
                "spoke": saw_geniepod,
                "transcript": transcript,
            }
        )
        in_cycle = False
        saw_recording = False
        saw_you_said = False
        saw_geniepod = False
        transcript = ""

missing = max(0, expect - len(cycles))
stalls += missing
passed = len(cycles) >= expect and stalls == 0 and silent_drops == 0

ledger = {
    "log": log_path,
    "expect_cycles": expect,
    "completed_cycles": len(cycles),
    "stalls": stalls,
    "silent_drops": silent_drops,
    "partial_failures": failures,
    "max_cycle_ms_budget": max_ms,
    "pass": passed,
    "cycles": cycles,
}

with open(ledger_path, "w", encoding="utf-8") as out:
    json.dump(ledger, out, indent=2)
    out.write("\n")

sys.exit(0 if passed else 1)
PY

    local pass=0
    if jq -e '.pass == true' "${ledger_path}" >/dev/null 2>&1; then
        pass=1
    fi

    echo "=== 100-cycle voice soak (issue #109) ==="
    jq -r '
        "Log:               \(.log)",
        "Expected cycles:   \(.expect_cycles)",
        "Completed cycles:  \(.completed_cycles)",
        "Stalls:            \(.stalls)",
        "Silent drops:      \(.silent_drops)",
        "Partial failures:  \(.partial_failures)",
        "Result:            \(if .pass then "PASS" else "FAIL" end)"
    ' "${ledger_path}"
    echo "Ledger: ${ledger_path}"

    if [[ "${pass}" -eq 1 ]]; then
        return 0
    fi
    return 1
}

cmd_run() {
    local cycles="${DEFAULT_CYCLES}"
    local config="${GENIEPOD_CONFIG:-}"
    local log_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cycles)
                cycles="$2"
                shift 2
                ;;
            --config)
                config="$2"
                shift 2
                ;;
            --log)
                log_path="$2"
                shift 2
                ;;
            *)
                echo "error: unknown run option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    require_cmd jq
    local binary="${REPO_ROOT}/target/release/genie-core"
    if [[ ! -x "${binary}" ]]; then
        binary="${REPO_ROOT}/target/debug/genie-core"
    fi
    if [[ ! -x "${binary}" ]]; then
        echo "error: build genie-core first (cargo build -p genie-core --release)" >&2
        exit 1
    fi

    mkdir -p "${OUT_DIR}"
    if [[ -z "${log_path}" ]]; then
        log_path="${OUT_DIR}/soak-$(date -u +%Y%m%dT%H%M%SZ).log"
    fi
    local ledger_path="${log_path%.log}.json"

    echo "=== M1 voice soak — run mode ==="
    echo "Target cycles:  ${cycles}"
    echo "Log file:       ${log_path}"
    echo "Binary:         ${binary}"
    if [[ -n "${config}" ]]; then
        echo "Config:         ${config}"
        export GENIEPOD_CONFIG="${config}"
    else
        echo "Config:         (GENIEPOD_CONFIG unset — genie-core default)"
    fi
    echo
    echo "Complete ${cycles} voice cycles (wake word or push-to-talk), then exit genie-core (Ctrl+C)."
    echo "stderr is tee'd to the log; analysis runs on exit."
    echo

  set +e
  "${binary}" --voice 2>&1 | tee "${log_path}"
  local core_status=${PIPESTATUS[0]}
  set -e

    echo
    echo "genie-core exited with status ${core_status}"
    analyze_log "${log_path}" "${cycles}" "${ledger_path}" "${MAX_CYCLE_MS}"
}

cmd_analyze() {
    local log_path=""
    local expect_cycles="${DEFAULT_CYCLES}"
    local ledger_path=""
    local max_cycle_ms="${MAX_CYCLE_MS}"

    if [[ $# -lt 1 ]]; then
        echo "error: analyze requires a LOG path" >&2
        usage
        exit 1
    fi
    log_path=$1
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expect-cycles)
                expect_cycles="$2"
                shift 2
                ;;
            --ledger)
                ledger_path="$2"
                shift 2
                ;;
            --max-cycle-ms)
                max_cycle_ms="$2"
                shift 2
                ;;
            *)
                echo "error: unknown analyze option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    require_cmd jq
    if [[ -z "${ledger_path}" ]]; then
        ledger_path="${log_path%.log}.json"
        if [[ "${ledger_path}" == "${log_path}" ]]; then
            ledger_path="${log_path}.ledger.json"
        fi
    fi

    analyze_log "${log_path}" "${expect_cycles}" "${ledger_path}" "${max_cycle_ms}"
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd=$1
    shift

    case "${cmd}" in
        run) cmd_run "$@" ;;
        analyze) cmd_analyze "$@" ;;
        -h | --help | help) usage ;;
        *)
            echo "error: unknown command: ${cmd}" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
