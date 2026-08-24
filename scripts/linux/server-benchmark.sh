#!/bin/bash

# Prüfen, ob sysbench installiert ist
if ! command -v sysbench &> /dev/null
then
    echo "Error: sysbench ist nicht installiert."
    exit 1
fi

# Prüfen, ob iperf3 installiert ist
if ! command -v iperf3 &> /dev/null
then
    echo "Error: iperf3 ist nicht installiert."
    exit 1
fi

# Prüfen, ob fio installiert ist
if ! command -v fio &> /dev/null
then
    echo "Error: fio ist nicht installiert."
    exit 1
fi

REPORT_FILE="benchmark_report_$(date +%Y%m%d_%H%M%S).txt"

{
    echo "========================================"
    echo "Starte Server Benchmark"
    echo "Datum: $(date)"
    echo "========================================"

    # System-Metadaten
    echo "SYSTEM INFORMATIONEN"
    echo "----------------------------------------"
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    CPU_CORES=$(nproc)
    OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    KERNEL=$(uname -r)
    echo "CPU:    $CPU_MODEL ($CPU_CORES Kerne)"
    echo "OS:     $OS_NAME"
    echo "Kernel: $KERNEL"
    echo "----------------------------------------"

    # 1. CPU Bench: Nur ein Kern
    echo ""
    echo "1. CPU Benchmark (Single-Core)"
    echo "----------------------------------------"
    CPU_OUT=$(sysbench cpu --threads=1 --cpu-max-prime=20000 --time=30 run)
    echo "$CPU_OUT"

    # 2. RAM Bench: Write
    echo ""
    echo "2. RAM Benchmark (Write, 1M Blocks)"
    echo "----------------------------------------"
    MEM_WRITE_OUT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write run)
    echo "$MEM_WRITE_OUT"

    # 3. RAM Bench: Read
    echo ""
    echo "3. RAM Benchmark (Read, 1M Blocks)"
    echo "----------------------------------------"
    MEM_READ_OUT=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read run)
    echo "$MEM_READ_OUT"

    # 4. Network Bench: iperf3
    echo ""
    echo "4. Network Benchmark (Standard)"
    echo "----------------------------------------"
    NET_OUT=$(iperf3 -c speedtest.myloc.de -p 5200 -P 10 -4)
    echo "$NET_OUT" | grep "SUM"

    echo ""
    echo "5. Network Benchmark (Reverse)"
    echo "----------------------------------------"
    NET_REV_OUT=$(iperf3 -c speedtest.myloc.de -p 5200 -P 10 -4 -R)
    echo "$NET_REV_OUT" | grep "SUM"

    # 6. Network Latency: Ping
    echo ""
    echo "6. Network Latency (Ping to 8.8.8.8)"
    echo "----------------------------------------"
    PING_OUT=$(ping -c 10 8.8.8.8)
    echo "$PING_OUT"

    # 7. IO Bench: Optimiert für DB & Gameserver (4K Blocks, 4 Threads, Cache disabled)
    echo ""
    echo "7. IO Benchmark (Random Read/Write, 4K, 4 Threads, 60s, Direct I/O)"
    echo "----------------------------------------"
    echo "Vorbereitung..."
    sysbench fileio --file-total-size=1G prepare > /dev/null
    IO_OUT=$(sysbench fileio --file-total-size=1G --file-test-mode=rndrw --file-block-size=4K --threads=4 --file-extra-flags=direct --time=60 run)
    echo "$IO_OUT"
    echo "Bereinigung..."
    sysbench fileio --file-total-size=1G cleanup > /dev/null

    # 8. FIO Multi-Blocksize Disk Speed Test (4k, 64k, 512k, 1m)
    echo ""
    echo "8. FIO Multi-Blocksize Benchmark (4k, 64k, 512k, 1m - Direct I/O, 70/30 R/W)"
    echo "----------------------------------------"
    if [ ! -d "/root/fiotest" ]; then
        echo "Erstelle Verzeichnis /root/fiotest..."
        mkdir -p /root/fiotest
    fi

    declare -A FIO_BS_READ_BW
    declare -A FIO_BS_READ_IOPS
    declare -A FIO_BS_READ_LAT
    declare -A FIO_BS_WRITE_BW
    declare -A FIO_BS_WRITE_IOPS
    declare -A FIO_BS_WRITE_LAT

    BLOCK_SIZES=("4k" "64k" "512k" "1m")
    for BS in "${BLOCK_SIZES[@]}"; do
        echo ">> Teste Blockgröße: $BS..."
        BS_OUT=$(fio --name="bench_$BS" --directory=/root/fiotest --size=2G \
          --time_based --runtime=30s --ramp_time=5s \
          --ioengine=libaio --direct=1 --bs="$BS" --iodepth=32 \
          --rw=randrw --rwmixread=70 --numjobs=4 --group_reporting)
        echo "$BS_OUT"
        rm -rf /root/fiotest/bench_"$BS"*

        FIO_BS_READ_IOPS["$BS"]=$(echo "$BS_OUT" | grep "read:" | awk -F'[,=]' '{print $2}' | xargs)
        FIO_BS_READ_BW["$BS"]=$(echo "$BS_OUT" | grep "read:" | awk -F'[,=]' '{print $4}' | xargs)
        FIO_BS_READ_LAT_UNIT=$(echo "$BS_OUT" | grep -A 15 "read:" | grep -E "^\s+lat \(" | head -1 | awk -F'[()]' '{print $2}')
        FIO_BS_READ_LAT_AVG=$(echo "$BS_OUT" | grep -A 15 "read:" | grep -E "^\s+lat \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
        FIO_BS_READ_LAT["$BS"]="${FIO_BS_READ_LAT_AVG}${FIO_BS_READ_LAT_UNIT}"

        FIO_BS_WRITE_IOPS["$BS"]=$(echo "$BS_OUT" | grep "write:" | awk -F'[,=]' '{print $2}' | xargs)
        FIO_BS_WRITE_BW["$BS"]=$(echo "$BS_OUT" | grep "write:" | awk -F'[,=]' '{print $4}' | xargs)
        FIO_BS_WRITE_LAT_UNIT=$(echo "$BS_OUT" | grep -A 15 "write:" | grep -E "^\s+lat \(" | head -1 | awk -F'[()]' '{print $2}')
        FIO_BS_WRITE_LAT_AVG=$(echo "$BS_OUT" | grep -A 15 "write:" | grep -E "^\s+lat \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
        FIO_BS_WRITE_LAT["$BS"]="${FIO_BS_WRITE_LAT_AVG}${FIO_BS_WRITE_LAT_UNIT}"
    done

    # 9. FIO IO Bench: DB Sync Simulation (fsync=1)
    echo ""
    echo "9. FIO IO Benchmark (DB Sync Simulation, 4K, 4G, 120s, Direct I/O, fsync=1)"
    echo "----------------------------------------"
    FIO_FSYNC_OUT=$(fio --name=sustained_randrw_fsync --directory=/root/fiotest --size=4G \
      --time_based --runtime=120s --ramp_time=10s \
      --ioengine=libaio --direct=1 --bs=4k --iodepth=32 \
      --rw=randrw --rwmixread=70 --numjobs=4 --group_reporting \
      --fsync=1)
    echo "$FIO_FSYNC_OUT"
    rm -rf /root/fiotest/sustained_randrw_fsync*

    # Werte extrahieren
    CPU_EPS=$(echo "$CPU_OUT" | grep "events per second:" | awk '{print $4}')
    MEM_WRITE_SPEED=$(echo "$MEM_WRITE_OUT" | grep "transferred (" | awk -F'(' '{print $2}' | awk -F')' '{print $1}')
    MEM_READ_SPEED=$(echo "$MEM_READ_OUT" | grep "transferred (" | awk -F'(' '{print $2}' | awk -F')' '{print $1}')
    
    NET_BITRATE=$(echo "$NET_OUT" | grep "sender" | awk '{print $(NF-2), $(NF-1)}')
    NET_REV_BITRATE=$(echo "$NET_REV_OUT" | grep "receiver" | awk '{print $(NF-2), $(NF-1)}')

    PING_AVG=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $5}')
    PING_JITTER=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $7}' | awk '{print $1}')

    IO_READ=$(echo "$IO_OUT" | grep "read, MiB/s:" | awk '{print $3}')
    IO_WRITE=$(echo "$IO_OUT" | grep "written, MiB/s:" | awk '{print $3}')
    IO_MIN=$(echo "$IO_OUT" | grep "min:" | awk '{print $2}')
    IO_MAX=$(echo "$IO_OUT" | grep "max:" | awk '{print $2}')
    IO_LATENCY=$(echo "$IO_OUT" | grep "95th percentile:" | awk '{print $3}')

    FIO_FSYNC_READ_IOPS=$(echo "$FIO_FSYNC_OUT" | grep "read:" | awk -F'[,=]' '{print $2}' | xargs)
    FIO_FSYNC_READ_BW=$(echo "$FIO_FSYNC_OUT" | grep "read:" | awk -F'[,=]' '{print $4}' | xargs)
    FIO_FSYNC_READ_LAT_UNIT=$(echo "$FIO_FSYNC_OUT" | grep -A 15 "read:" | grep -E "^\s+lat \(" | head -1 | awk -F'[()]' '{print $2}')
    FIO_FSYNC_READ_LAT_AVG=$(echo "$FIO_FSYNC_OUT" | grep -A 15 "read:" | grep -E "^\s+lat \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
    FIO_FSYNC_READ_LAT="${FIO_FSYNC_READ_LAT_AVG}${FIO_FSYNC_READ_LAT_UNIT}"

    FIO_FSYNC_WRITE_IOPS=$(echo "$FIO_FSYNC_OUT" | grep "write:" | awk -F'[,=]' '{print $2}' | xargs)
    FIO_FSYNC_WRITE_BW=$(echo "$FIO_FSYNC_OUT" | grep "write:" | awk -F'[,=]' '{print $4}' | xargs)
    FIO_FSYNC_WRITE_LAT_UNIT=$(echo "$FIO_FSYNC_OUT" | grep -A 15 "write:" | grep -E "^\s+lat \(" | head -1 | awk -F'[()]' '{print $2}')
    FIO_FSYNC_WRITE_LAT_AVG=$(echo "$FIO_FSYNC_OUT" | grep -A 15 "write:" | grep -E "^\s+lat \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
    FIO_FSYNC_WRITE_LAT="${FIO_FSYNC_WRITE_LAT_AVG}${FIO_FSYNC_WRITE_LAT_UNIT}"

    # Fsync Latency (Zeit pro Disk Flush)
    FIO_FSYNC_SYNC_UNIT=$(echo "$FIO_FSYNC_OUT" | grep -E "^\s+sync \(" | head -1 | awk -F'[()]' '{print $2}')
    FIO_FSYNC_SYNC_AVG=$(echo "$FIO_FSYNC_OUT" | grep -E "^\s+sync \(" | head -1 | awk -F'avg=' '{print $2}' | awk -F',' '{print $1}' | xargs)
    FIO_FSYNC_SYNC_LAT="${FIO_FSYNC_SYNC_AVG}${FIO_FSYNC_SYNC_UNIT}"

    echo ""
    echo "========================================"
    echo "ZUSAMMENFASSUNG (KOMPRIMIERT)"
    echo "========================================"
    echo "CPU Performance:  $CPU_EPS events/s"
    echo "RAM Write Speed:  $MEM_WRITE_SPEED"
    echo "RAM Read Speed:   $MEM_READ_SPEED"
    echo "Net Download:     $NET_REV_BITRATE"
    echo "Net Upload:       $NET_BITRATE"
    echo "Net Latency:      $PING_AVG ms (Jitter: $PING_JITTER ms)"
    echo "Sysbench Read:    $IO_READ MiB/s"
    echo "Sysbench Write:   $IO_WRITE MiB/s"
    echo "Sysbench Latency: $IO_LATENCY ms (Min/Max: $IO_MIN/$IO_MAX ms)"
    echo "----------------------------------------"
    echo "FIO Disk Speed Tests (Random R/W 70/30):"
    for BS in "${BLOCK_SIZES[@]}"; do
        printf "  - Block %-5s Read: %-10s (%-8s IOPS, Lat: %-8s) | Write: %-10s (%-8s IOPS, Lat: %-8s)\n" \
          "$BS" "${FIO_BS_READ_BW[$BS]}" "${FIO_BS_READ_IOPS[$BS]}" "${FIO_BS_READ_LAT[$BS]}" \
          "${FIO_BS_WRITE_BW[$BS]}" "${FIO_BS_WRITE_IOPS[$BS]}" "${FIO_BS_WRITE_LAT[$BS]}"
    done
    echo "----------------------------------------"
    echo "FIO Sync 4k (DB Commit Simulation mit fsync=1):"
    echo "  - Read:         $FIO_FSYNC_READ_BW ($FIO_FSYNC_READ_IOPS IOPS, Lat: $FIO_FSYNC_READ_LAT)"
    echo "  - Write:        $FIO_FSYNC_WRITE_BW ($FIO_FSYNC_WRITE_IOPS IOPS, Lat: $FIO_FSYNC_WRITE_LAT)"
    echo "  - Disk Flush:   Durchschnittliche fsync-Latenz: $FIO_FSYNC_SYNC_LAT"
    echo "========================================"
    echo ""
    echo "Benchmark abgeschlossen."
    echo "========================================"
} | tee "$REPORT_FILE"

echo ""
echo "Report wurde gespeichert in: $REPORT_FILE"
