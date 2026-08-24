#!/bin/bash
#
# server-benchmark.sh — Linux-Server-Benchmark mit wählbaren Workload-Profilen
#
# Verwendung:
#   ./server-benchmark.sh install                    # installiert benötigte Pakete (sysbench, fio, iperf3, jq)
#   ./server-benchmark.sh --profile base             # nur Basis-Tests (Default)
#   ./server-benchmark.sh --profile db               # Basis + Datenbank-Tests
#   ./server-benchmark.sh --profile game             # Basis + Game-Server-Tests
#   ./server-benchmark.sh --profile app              # Basis + Applikations-Tests
#   ./server-benchmark.sh --profile k8s              # Basis + Kubernetes-Host-Tests
#   ./server-benchmark.sh --profile all              # alle Profile
#   ./server-benchmark.sh --profile db --report-dir /var/log/bench   # optionales Report-Ziel
#
# Siehe benchmark-konzept.md für Details zu Profilen und Interpretation.

set -u

# ----------------------------------------------------------------------------
# Konfiguration
# ----------------------------------------------------------------------------
PROFILE="base"
REPORT_DIR="."
IPERF_HOST="speedtest.myloc.de"
IPERF_PORT="5200"
FIO_DIR="/root/fiotest"
PING_TARGETS_GAME=("8.8.8.8" "1.1.1.1" "speedtest.myloc.de")

# ----------------------------------------------------------------------------
# install: benötigte Pakete installieren
# ----------------------------------------------------------------------------
do_install() {
    local PKGS=(sysbench fio iperf3 jq)
    echo "Installiere benötigte Pakete: ${PKGS[*]}"

    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
        if ! command -v sudo &> /dev/null; then
            echo "Error: Bitte als root ausführen (oder sudo installieren)."
            exit 1
        fi
    else
        SUDO=""
    fi

    if command -v apt-get &> /dev/null; then
        $SUDO apt-get update
        $SUDO apt-get install -y "${PKGS[@]}"
    elif command -v dnf &> /dev/null; then
        $SUDO dnf install -y "${PKGS[@]}"
    elif command -v yum &> /dev/null; then
        $SUDO yum install -y "${PKGS[@]}"
    elif command -v zypper &> /dev/null; then
        $SUDO zypper --non-interactive install "${PKGS[@]}"
    elif command -v pacman &> /dev/null; then
        $SUDO pacman -Sy --noconfirm "${PKGS[@]}"
    elif command -v apk &> /dev/null; then
        $SUDO apk add "${PKGS[@]}"
    else
        echo "Error: Kein unterstützter Paketmanager gefunden (apt, dnf, yum, zypper, pacman, apk)."
        exit 1
    fi

    echo ""
    echo "Prüfe Installation..."
    local MISSING=0
    for TOOL in "${PKGS[@]}"; do
        if command -v "$TOOL" &> /dev/null; then
            echo "  [OK]      $TOOL"
        else
            echo "  [FEHLT]   $TOOL"
            MISSING=1
        fi
    done
    if [ "$MISSING" -eq 1 ]; then
        echo "Error: Nicht alle Tools konnten installiert werden."
        exit 1
    fi
    echo "Installation abgeschlossen."
    exit 0
}

usage() {
    grep '^#   ' "$0" | sed 's/^#   //'
    exit 1
}

# ----------------------------------------------------------------------------
# Argumente parsen
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        install)
            do_install
            ;;
        --profile)
            PROFILE="${2:-}"
            [ -z "$PROFILE" ] && usage
            shift 2
            ;;
        --report-dir)
            REPORT_DIR="${2:-}"
            [ -z "$REPORT_DIR" ] && usage
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unbekanntes Argument: $1"
            usage
            ;;
    esac
done

case "$PROFILE" in
    base|db|game|app|k8s|all) ;;
    *)
        echo "Error: Ungültiges Profil: $PROFILE (erlaubt: base|db|game|app|k8s|all)"
        exit 1
        ;;
esac

profile_active() {
    # base läuft immer mit; "all" aktiviert alles
    [ "$1" = "base" ] && return 0
    [ "$PROFILE" = "all" ] && return 0
    [ "$PROFILE" = "$1" ] && return 0
    return 1
}

# ----------------------------------------------------------------------------
# Tool-Checks: nur für die im gewählten Profil benötigten Tools
# ----------------------------------------------------------------------------
REQUIRED_TOOLS=(sysbench iperf3 jq ping)
if profile_active db || profile_active game || profile_active app || profile_active k8s; then
    REQUIRED_TOOLS+=(fio)
fi

MISSING_TOOLS=()
for TOOL in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$TOOL" &> /dev/null; then
        MISSING_TOOLS+=("$TOOL")
    fi
done
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "Error: Folgende Tools sind nicht installiert: ${MISSING_TOOLS[*]}"
    echo "Tipp: ./$(basename "$0") install"
    exit 1
fi

mkdir -p "$REPORT_DIR"
REPORT_FILE="$REPORT_DIR/benchmark_report_$(date +%Y%m%d_%H%M%S).txt"

# ----------------------------------------------------------------------------
# Hilfsfunktionen
# ----------------------------------------------------------------------------
NPROC=$(nproc)

ensure_fio_dir() {
    if [ ! -d "$FIO_DIR" ]; then
        echo "Erstelle Verzeichnis $FIO_DIR..."
        mkdir -p "$FIO_DIR"
    fi
}

# fio-Ausgabe parsen: <out> <read|write>
fio_iops()  { echo "$1" | grep "$2:" | awk -F'[,=]' '{print $2}' | xargs; }
fio_bw()    { echo "$1" | grep "$2:" | awk -F'[,=]' '{print $4}' | xargs; }
fio_lat() {
    local UNIT AVG
    UNIT=$(echo "$1" | grep -A 15 "$2:" | grep -E "^\s+lat \(" | head -1 | awk -F'[()]' '{print $2}')
    AVG=$(echo "$1" | grep -A 15 "$2:" | grep -E "^\s+lat \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
    echo "${AVG}${UNIT}"
}
fio_sync_lat() {
    local UNIT AVG
    UNIT=$(echo "$1" | grep -E "^\s+sync \(" | head -1 | awk -F'[()]' '{print $2}')
    AVG=$(echo "$1" | grep -E "^\s+sync \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
    echo "${AVG}${UNIT}"
}

section() {
    echo ""
    echo "$1"
    echo "----------------------------------------"
}

# ----------------------------------------------------------------------------
# Test-Module (laufen jeweils nur einmal, auch wenn mehrere Profile sie nutzen)
# ----------------------------------------------------------------------------

RAN_SYSINFO=0
run_sysinfo() {
    [ "$RAN_SYSINFO" -eq 1 ] && return; RAN_SYSINFO=1
    section "SYSTEM INFORMATIONEN"
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    KERNEL=$(uname -r)
    echo "CPU:    $CPU_MODEL ($NPROC Kerne)"
    echo "OS:     $OS_NAME"
    echo "Kernel: $KERNEL"
}

RAN_CPU_SINGLE=0
run_cpu_single() {
    [ "$RAN_CPU_SINGLE" -eq 1 ] && return; RAN_CPU_SINGLE=1
    section "CPU Benchmark (Single-Core)"
    CPU_OUT=$(sysbench cpu --threads=1 --cpu-max-prime=20000 --time=30 run)
    echo "$CPU_OUT"
    CPU_EPS=$(echo "$CPU_OUT" | grep "events per second:" | awk '{print $4}')
}

RAN_CPU_MULTI=0
run_cpu_multi() {
    [ "$RAN_CPU_MULTI" -eq 1 ] && return; RAN_CPU_MULTI=1
    section "CPU Benchmark (Multi-Core, $NPROC Threads)"
    CPU_MULTI_OUT=$(sysbench cpu --threads="$NPROC" --cpu-max-prime=20000 --time=30 run)
    echo "$CPU_MULTI_OUT"
    CPU_MULTI_EPS=$(echo "$CPU_MULTI_OUT" | grep "events per second:" | awk '{print $4}')
    CPU_SCALE=$(awk -v m="$CPU_MULTI_EPS" -v s="$CPU_EPS" 'BEGIN{ if (s>0) printf "%.2f", m/s; else print "n/a" }')
}

RAN_RAM=0
run_ram() {
    [ "$RAN_RAM" -eq 1 ] && return; RAN_RAM=1
    section "RAM Benchmark (Write, 1M Blocks)"
    MEM_WRITE_OUT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write run)
    echo "$MEM_WRITE_OUT"
    MEM_WRITE_SPEED=$(echo "$MEM_WRITE_OUT" | grep "transferred (" | awk -F'(' '{print $2}' | awk -F')' '{print $1}')

    section "RAM Benchmark (Read, 1M Blocks)"
    MEM_READ_OUT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read run)
    echo "$MEM_READ_OUT"
    MEM_READ_SPEED=$(echo "$MEM_READ_OUT" | grep "transferred (" | awk -F'(' '{print $2}' | awk -F')' '{print $1}')
}

RAN_NET=0
run_net() {
    [ "$RAN_NET" -eq 1 ] && return; RAN_NET=1
    section "Network Benchmark (Upload, iperf3 -P 10)"
    NET_JSON=$(iperf3 -c "$IPERF_HOST" -p "$IPERF_PORT" -P 10 -4 --json)
    NET_UP_BPS=$(echo "$NET_JSON" | jq -r '.end.sum_sent.bits_per_second // 0')
    NET_BITRATE=$(awk -v b="$NET_UP_BPS" 'BEGIN{printf "%.2f Gbit/s", b/1e9}')
    echo "Upload: $NET_BITRATE"

    section "Network Benchmark (Download, iperf3 -P 10 -R)"
    NET_REV_JSON=$(iperf3 -c "$IPERF_HOST" -p "$IPERF_PORT" -P 10 -4 -R --json)
    NET_DOWN_BPS=$(echo "$NET_REV_JSON" | jq -r '.end.sum_received.bits_per_second // 0')
    NET_REV_BITRATE=$(awk -v b="$NET_DOWN_BPS" 'BEGIN{printf "%.2f Gbit/s", b/1e9}')
    echo "Download: $NET_REV_BITRATE"
}

RAN_PING=0
run_ping() {
    [ "$RAN_PING" -eq 1 ] && return; RAN_PING=1
    section "Network Latency (Ping to 8.8.8.8)"
    PING_OUT=$(ping -c 10 8.8.8.8)
    echo "$PING_OUT"
    PING_AVG=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $5}')
    PING_JITTER=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $7}' | awk '{print $1}')
}

RAN_SYSBENCH_IO=0
run_sysbench_io() {
    [ "$RAN_SYSBENCH_IO" -eq 1 ] && return; RAN_SYSBENCH_IO=1
    section "IO Benchmark (Random Read/Write, 4K, 4 Threads, 20s, Direct I/O)"
    echo "Vorbereitung..."
    sysbench fileio --file-total-size=1G prepare > /dev/null
    IO_OUT=$(sysbench fileio --file-total-size=1G --file-test-mode=rndrw --file-block-size=4K --threads=4 --file-extra-flags=direct --time=20 run)
    echo "$IO_OUT"
    echo "Bereinigung..."
    sysbench fileio --file-total-size=1G cleanup > /dev/null
    IO_READ=$(echo "$IO_OUT" | grep "read, MiB/s:" | awk '{print $3}')
    IO_WRITE=$(echo "$IO_OUT" | grep "written, MiB/s:" | awk '{print $3}')
    IO_MIN=$(echo "$IO_OUT" | grep "min:" | awk '{print $2}')
    IO_MAX=$(echo "$IO_OUT" | grep "max:" | awk '{print $2}')
    IO_LATENCY=$(echo "$IO_OUT" | grep "95th percentile:" | awk '{print $3}')
}

declare -A FIO_BS_READ_BW FIO_BS_READ_IOPS FIO_BS_READ_LAT
declare -A FIO_BS_WRITE_BW FIO_BS_WRITE_IOPS FIO_BS_WRITE_LAT
FIO_BS_TESTED=()
run_fio_blocksize() {
    # $@: zu testende Blockgrößen; bereits getestete werden übersprungen
    ensure_fio_dir
    local BS
    for BS in "$@"; do
        [ -n "${FIO_BS_READ_BW[$BS]:-}" ] && continue
        section "FIO Blocksize Benchmark ($BS - Direct I/O, 70/30 R/W, 15s)"
        local BS_OUT
        BS_OUT=$(fio --name="bench_$BS" --directory="$FIO_DIR" --size=1G \
          --time_based --runtime=15s --ramp_time=3s \
          --ioengine=libaio --direct=1 --bs="$BS" --iodepth=32 \
          --rw=randrw --rwmixread=70 --numjobs=4 --group_reporting)
        echo "$BS_OUT"
        rm -rf "$FIO_DIR"/bench_"$BS"*
        FIO_BS_READ_IOPS["$BS"]=$(fio_iops "$BS_OUT" read)
        FIO_BS_READ_BW["$BS"]=$(fio_bw "$BS_OUT" read)
        FIO_BS_READ_LAT["$BS"]=$(fio_lat "$BS_OUT" read)
        FIO_BS_WRITE_IOPS["$BS"]=$(fio_iops "$BS_OUT" write)
        FIO_BS_WRITE_BW["$BS"]=$(fio_bw "$BS_OUT" write)
        FIO_BS_WRITE_LAT["$BS"]=$(fio_lat "$BS_OUT" write)
        FIO_BS_TESTED+=("$BS")
    done
}

RAN_FIO_FSYNC=0
run_fio_fsync() {
    [ "$RAN_FIO_FSYNC" -eq 1 ] && return; RAN_FIO_FSYNC=1
    ensure_fio_dir
    section "FIO IO Benchmark (DB Sync Simulation, 4K, 2G, 30s, Direct I/O, fsync=1)"
    FIO_FSYNC_OUT=$(fio --name=sustained_randrw_fsync --directory="$FIO_DIR" --size=2G \
      --time_based --runtime=30s --ramp_time=5s \
      --ioengine=libaio --direct=1 --bs=4k --iodepth=32 \
      --rw=randrw --rwmixread=70 --numjobs=4 --group_reporting \
      --fsync=1)
    echo "$FIO_FSYNC_OUT"
    rm -rf "$FIO_DIR"/sustained_randrw_fsync*
    FIO_FSYNC_READ_IOPS=$(fio_iops "$FIO_FSYNC_OUT" read)
    FIO_FSYNC_READ_BW=$(fio_bw "$FIO_FSYNC_OUT" read)
    FIO_FSYNC_READ_LAT=$(fio_lat "$FIO_FSYNC_OUT" read)
    FIO_FSYNC_WRITE_IOPS=$(fio_iops "$FIO_FSYNC_OUT" write)
    FIO_FSYNC_WRITE_BW=$(fio_bw "$FIO_FSYNC_OUT" write)
    FIO_FSYNC_WRITE_LAT=$(fio_lat "$FIO_FSYNC_OUT" write)
    FIO_FSYNC_SYNC_LAT=$(fio_sync_lat "$FIO_FSYNC_OUT")
}

RAN_FIO_QD1=0
run_fio_qd1() {
    [ "$RAN_FIO_QD1" -eq 1 ] && return; RAN_FIO_QD1=1
    ensure_fio_dir
    section "FIO IO Benchmark (Commit-Latenz / etcd-Proxy-Metrik, 4K, QD1, 15s, Direct I/O, fdatasync=1)"
    FIO_QD1_FSYNC_OUT=$(fio --name=qd1_fdatasync --directory="$FIO_DIR" --size=512M \
      --time_based --runtime=15s --ramp_time=3s \
      --ioengine=libaio --direct=1 --bs=4k --iodepth=1 \
      --rw=write --numjobs=1 --group_reporting \
      --fdatasync=1)
    echo "$FIO_QD1_FSYNC_OUT"
    rm -rf "$FIO_DIR"/qd1_fdatasync*
    FIO_QD1_WRITE_IOPS=$(fio_iops "$FIO_QD1_FSYNC_OUT" write)
    FIO_QD1_WRITE_BW=$(fio_bw "$FIO_QD1_FSYNC_OUT" write)
    FIO_QD1_WRITE_LAT=$(fio_lat "$FIO_QD1_FSYNC_OUT" write)
    FIO_QD1_SYNC_LAT=$(fio_sync_lat "$FIO_QD1_FSYNC_OUT")
}

declare -A FIO_QDN_WRITE_BW FIO_QDN_WRITE_IOPS FIO_QDN_WRITE_LAT
QUEUE_DEPTHS=("4" "16")
RAN_FIO_QDN=0
run_fio_qdn() {
    [ "$RAN_FIO_QDN" -eq 1 ] && return; RAN_FIO_QDN=1
    ensure_fio_dir
    section "FIO IO Benchmark (Parallele Sync-Writes, 4K, QD4/QD16, 15s, Direct I/O, fdatasync=1)"
    local QD QDN_OUT
    for QD in "${QUEUE_DEPTHS[@]}"; do
        echo ">> Teste Queue Depth: $QD..."
        QDN_OUT=$(fio --name="qd${QD}_fdatasync" --directory="$FIO_DIR" --size=512M \
          --time_based --runtime=15s --ramp_time=3s \
          --ioengine=libaio --direct=1 --bs=4k --iodepth="$QD" \
          --rw=write --numjobs=1 --group_reporting \
          --fdatasync=1)
        echo "$QDN_OUT"
        rm -rf "$FIO_DIR"/qd"${QD}"_fdatasync*
        FIO_QDN_WRITE_IOPS["$QD"]=$(fio_iops "$QDN_OUT" write)
        FIO_QDN_WRITE_BW["$QD"]=$(fio_bw "$QDN_OUT" write)
        FIO_QDN_WRITE_LAT["$QD"]=$(fio_lat "$QDN_OUT" write)
    done
}

RAN_FIO_SEQ=0
run_fio_seq_write() {
    [ "$RAN_FIO_SEQ" -eq 1 ] && return; RAN_FIO_SEQ=1
    ensure_fio_dir
    section "FIO IO Benchmark (1M Sequential Write, Dauerlast, 20s, Direct I/O)"
    FIO_SEQ_WRITE_OUT=$(fio --name=seq_write_1m --directory="$FIO_DIR" --size=2G \
      --time_based --runtime=20s --ramp_time=3s \
      --ioengine=libaio --direct=1 --bs=1m --iodepth=4 \
      --rw=write --numjobs=1 --group_reporting)
    echo "$FIO_SEQ_WRITE_OUT"
    rm -rf "$FIO_DIR"/seq_write_1m*
    FIO_SEQ_WRITE_IOPS=$(fio_iops "$FIO_SEQ_WRITE_OUT" write)
    FIO_SEQ_WRITE_BW=$(fio_bw "$FIO_SEQ_WRITE_OUT" write)
    FIO_SEQ_WRITE_LAT=$(fio_lat "$FIO_SEQ_WRITE_OUT" write)
}

declare -A PING_MULTI_AVG PING_MULTI_MDEV
RAN_PING_MULTI=0
run_ping_multi() {
    [ "$RAN_PING_MULTI" -eq 1 ] && return; RAN_PING_MULTI=1
    local TARGET OUT
    for TARGET in "${PING_TARGETS_GAME[@]}"; do
        section "Network Latency (Ping to $TARGET, 20 Pakete)"
        OUT=$(ping -c 20 "$TARGET")
        echo "$OUT"
        PING_MULTI_AVG["$TARGET"]=$(echo "$OUT" | tail -1 | awk -F'/' '{print $5}')
        PING_MULTI_MDEV["$TARGET"]=$(echo "$OUT" | tail -1 | awk -F'/' '{print $7}' | awk '{print $1}')
    done
}

RAN_UDP_JITTER=0
run_udp_jitter() {
    [ "$RAN_UDP_JITTER" -eq 1 ] && return; RAN_UDP_JITTER=1
    section "Network UDP-Jitter (iperf3 -u -b 100M)"
    UDP_JSON=$(iperf3 -u -b 100M -c "$IPERF_HOST" -p "$IPERF_PORT" -4 --json)
    UDP_JITTER=$(echo "$UDP_JSON" | jq -r '.end.sum.jitter_ms // 0' | xargs printf "%.3f")
    UDP_LOSS=$(echo "$UDP_JSON" | jq -r '.end.sum.lost_percent // 0' | xargs printf "%.2f")
    echo "Jitter: $UDP_JITTER ms, Paketverlust: $UDP_LOSS %"
}

declare -A CPU_SCALE_EPS
CPU_SCALE_STEPS=()
RAN_CPU_SCALE=0
run_cpu_scaling() {
    [ "$RAN_CPU_SCALE" -eq 1 ] && return; RAN_CPU_SCALE=1
    section "CPU Multi-Core-Skalierung (sysbench, 10s pro Stufe)"
    local T=1 OUT
    while [ "$T" -lt "$NPROC" ]; do
        CPU_SCALE_STEPS+=("$T")
        T=$((T * 2))
    done
    CPU_SCALE_STEPS+=("$NPROC")
    for T in "${CPU_SCALE_STEPS[@]}"; do
        echo ">> Threads: $T..."
        OUT=$(sysbench cpu --threads="$T" --cpu-max-prime=20000 --time=10 run)
        CPU_SCALE_EPS["$T"]=$(echo "$OUT" | grep "events per second:" | awk '{print $4}')
        echo "   events/s: ${CPU_SCALE_EPS[$T]}"
    done
}

RAN_FIO_PARALLEL=0
run_fio_parallel_4k() {
    [ "$RAN_FIO_PARALLEL" -eq 1 ] && return; RAN_FIO_PARALLEL=1
    ensure_fio_dir
    section "FIO IO Benchmark (Viele kleine parallele I/Os, 4K, 8 Jobs, QD16, 15s, Direct I/O)"
    FIO_PAR_OUT=$(fio --name=parallel_4k --directory="$FIO_DIR" --size=1G \
      --time_based --runtime=15s --ramp_time=3s \
      --ioengine=libaio --direct=1 --bs=4k --iodepth=16 \
      --rw=randrw --rwmixread=70 --numjobs=8 --group_reporting)
    echo "$FIO_PAR_OUT"
    rm -rf "$FIO_DIR"/parallel_4k*
    FIO_PAR_READ_IOPS=$(fio_iops "$FIO_PAR_OUT" read)
    FIO_PAR_READ_BW=$(fio_bw "$FIO_PAR_OUT" read)
    FIO_PAR_WRITE_IOPS=$(fio_iops "$FIO_PAR_OUT" write)
    FIO_PAR_WRITE_BW=$(fio_bw "$FIO_PAR_OUT" write)
    FIO_PAR_WRITE_LAT=$(fio_lat "$FIO_PAR_OUT" write)
}

# ----------------------------------------------------------------------------
# Profile
# ----------------------------------------------------------------------------
run_base() {
    echo ""
    echo "========================================"
    echo "PROFIL: base"
    echo "========================================"
    run_sysinfo
    run_cpu_single
    run_cpu_multi
    run_ram
    run_net
    run_ping
}

run_db() {
    echo ""
    echo "========================================"
    echo "PROFIL: db"
    echo "========================================"
    run_sysbench_io
    run_fio_fsync
    run_fio_qd1
    run_fio_qdn
}

run_game() {
    echo ""
    echo "========================================"
    echo "PROFIL: game"
    echo "========================================"
    run_ping_multi
    run_udp_jitter
    run_fio_blocksize "4k"
}

run_app() {
    echo ""
    echo "========================================"
    echo "PROFIL: app"
    echo "========================================"
    run_fio_blocksize "4k" "64k" "512k" "1m"
    run_fio_seq_write
}

run_k8s() {
    echo ""
    echo "========================================"
    echo "PROFIL: k8s"
    echo "========================================"
    run_cpu_scaling
    run_fio_qd1
    run_fio_parallel_4k
}

# ----------------------------------------------------------------------------
# Zusammenfassung (pro Profil gruppiert)
# ----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "========================================"
    echo "ZUSAMMENFASSUNG (KOMPRIMIERT)"
    echo "========================================"

    echo "[base]"
    echo "CPU Single-Core:  $CPU_EPS events/s"
    echo "CPU Multi-Core:   $CPU_MULTI_EPS events/s (Skalierungsfaktor: ${CPU_SCALE}x bei $NPROC Kernen)"
    echo "RAM Write Speed:  $MEM_WRITE_SPEED"
    echo "RAM Read Speed:   $MEM_READ_SPEED"
    echo "Net Download:     $NET_REV_BITRATE"
    echo "Net Upload:       $NET_BITRATE"
    echo "Net Latency:      $PING_AVG ms (Jitter: $PING_JITTER ms)"

    if profile_active db; then
        echo "----------------------------------------"
        echo "[db]"
        echo "Sysbench Read:    $IO_READ MiB/s"
        echo "Sysbench Write:   $IO_WRITE MiB/s"
        echo "Sysbench Latency: $IO_LATENCY ms (Min/Max: $IO_MIN/$IO_MAX ms)"
        echo "FIO Sync 4k (DB Commit Simulation mit fsync=1):"
        echo "  - Read:         $FIO_FSYNC_READ_BW ($FIO_FSYNC_READ_IOPS IOPS, Lat: $FIO_FSYNC_READ_LAT)"
        echo "  - Write:        $FIO_FSYNC_WRITE_BW ($FIO_FSYNC_WRITE_IOPS IOPS, Lat: $FIO_FSYNC_WRITE_LAT)"
        echo "  - Disk Flush:   Durchschnittliche fsync-Latenz: $FIO_FSYNC_SYNC_LAT"
        echo "FIO Commit-Latenz 4k QD1 (fdatasync=1):"
        echo "  - Write:        $FIO_QD1_WRITE_BW ($FIO_QD1_WRITE_IOPS IOPS, Lat: $FIO_QD1_WRITE_LAT)"
        echo "  - Disk Flush:   Durchschnittliche fdatasync-Latenz: $FIO_QD1_SYNC_LAT"
        echo "FIO Parallele Sync-Writes 4k (fdatasync=1):"
        for QD in "${QUEUE_DEPTHS[@]}"; do
            printf "  - QD%-3s Write: %-10s (%-8s IOPS, Lat: %-8s)\n" \
              "$QD" "${FIO_QDN_WRITE_BW[$QD]}" "${FIO_QDN_WRITE_IOPS[$QD]}" "${FIO_QDN_WRITE_LAT[$QD]}"
        done
    fi

    if profile_active game; then
        echo "----------------------------------------"
        echo "[game]"
        for TARGET in "${PING_TARGETS_GAME[@]}"; do
            printf "Ping %-22s avg: %-8s ms (Jitter/mdev: %s ms)\n" \
              "$TARGET" "${PING_MULTI_AVG[$TARGET]:-n/a}" "${PING_MULTI_MDEV[$TARGET]:-n/a}"
        done
        echo "UDP-Jitter:       $UDP_JITTER ms (Paketverlust: $UDP_LOSS %)"
        echo "FIO 4k Random R/W 70/30:"
        printf "  - Read: %-10s (%-8s IOPS, Lat: %-8s) | Write: %-10s (%-8s IOPS, Lat: %-8s)\n" \
          "${FIO_BS_READ_BW[4k]}" "${FIO_BS_READ_IOPS[4k]}" "${FIO_BS_READ_LAT[4k]}" \
          "${FIO_BS_WRITE_BW[4k]}" "${FIO_BS_WRITE_IOPS[4k]}" "${FIO_BS_WRITE_LAT[4k]}"
    fi

    if profile_active app; then
        echo "----------------------------------------"
        echo "[app]"
        echo "FIO Disk Speed Tests (Random R/W 70/30):"
        for BS in "4k" "64k" "512k" "1m"; do
            printf "  - Block %-5s Read: %-10s (%-8s IOPS, Lat: %-8s) | Write: %-10s (%-8s IOPS, Lat: %-8s)\n" \
              "$BS" "${FIO_BS_READ_BW[$BS]}" "${FIO_BS_READ_IOPS[$BS]}" "${FIO_BS_READ_LAT[$BS]}" \
              "${FIO_BS_WRITE_BW[$BS]}" "${FIO_BS_WRITE_IOPS[$BS]}" "${FIO_BS_WRITE_LAT[$BS]}"
        done
        echo "FIO 1M Sequential Write (Dauerlast):"
        echo "  - Write:        $FIO_SEQ_WRITE_BW ($FIO_SEQ_WRITE_IOPS IOPS, Lat: $FIO_SEQ_WRITE_LAT)"
    fi

    if profile_active k8s; then
        echo "----------------------------------------"
        echo "[k8s]"
        echo "CPU-Skalierung (events/s pro Thread-Stufe):"
        for T in "${CPU_SCALE_STEPS[@]}"; do
            printf "  - %-3s Threads: %s events/s\n" "$T" "${CPU_SCALE_EPS[$T]}"
        done
        echo "etcd-Proxy-Metrik (fdatasync QD1): $FIO_QD1_SYNC_LAT (Richtwert: < 10 ms, ideal < 2 ms)"
        echo "FIO Parallel 4k (8 Jobs, QD16):"
        echo "  - Read:         $FIO_PAR_READ_BW ($FIO_PAR_READ_IOPS IOPS)"
        echo "  - Write:        $FIO_PAR_WRITE_BW ($FIO_PAR_WRITE_IOPS IOPS, Lat: $FIO_PAR_WRITE_LAT)"
    fi

    echo "========================================"
    echo ""
    echo "Benchmark abgeschlossen."
    echo "========================================"
}

# ----------------------------------------------------------------------------
# Hauptablauf
# ----------------------------------------------------------------------------
{
    echo "========================================"
    echo "Starte Server Benchmark (Profil: $PROFILE)"
    echo "Datum: $(date)"
    echo "========================================"

    run_base
    profile_active db   && run_db
    profile_active game && run_game
    profile_active app  && run_app
    profile_active k8s  && run_k8s

    print_summary
} | tee "$REPORT_FILE"

echo ""
echo "Report wurde gespeichert in: $REPORT_FILE"
