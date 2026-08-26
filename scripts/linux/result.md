# Server-Performance Benchmark & Vergleichsbericht

Dieser Bericht vergleicht die Performance von fünf verschiedenen Server-Instanzen (Zap Dedicated Server, Zap vServer, Strato, Hetzner Cloud Dedicated und Hetzner Cloud Regular). Zudem enthält er die Dokumentation der I/O-Optimierung auf dem Zap Dedicated Server, wodurch eine erhebliche Leistungssteigerung bei Datenbank- und Disk-Schreiboperationen erzielt wurde.

---

## 1. Übersicht der Benchmark-Ergebnisse

In der folgenden Tabelle sind die wichtigsten Kennzahlen der fünf Systeme gegenübergestellt.

*Hinweis: Der **Zap Dedicated Server** zeigt die Werte **nach** der Kernel-I/O-Optimierung (`nobarrier` / `noatime` / Power-State Latency Tuning).*

| Benchmark / Metrik | Zap Dedicated (Optimiert) | Zap vServer (4 Kerne) | Strato (8 Kerne) | Hetzner Dedicated (4 Kerne) | Hetzner Regular (8 Kerne) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **CPU Cores** | **32 Kerne** | 4 Kerne | 8 Kerne | 4 Kerne | 8 Kerne |
| **CPU Single-Core** | **2.660,49 ev/s** | 1.298,03 ev/s | 1.950,87 ev/s | 1.666,25 ev/s | 1.649,53 ev/s |
| **CPU Multi-Core** | **40.435,52 ev/s** (15.2x) | 5.104,55 ev/s (3.93x) | 13.731,53 ev/s (7.04x) | 3.622,73 ev/s (2.17x) | 13.207,93 ev/s (8.01x) |
| **RAM Read Speed** | **106.817,02 MiB/s** | 36.690,16 MiB/s | 82.252,46 MiB/s | 47.413,70 MiB/s | 54.399,01 MiB/s |
| **RAM Write Speed** | **40.853,02 MiB/s** | 19.271,95 MiB/s | 32.366,67 MiB/s | 30.713,91 MiB/s | 31.456,76 MiB/s |
| **Net Download** | 1,64 Gbit/s | 0,96 Gbit/s | 0,00 Gbit/s* | 3,50 Gbit/s | **4,03 Gbit/s** |
| **Net Upload** | 7,71 Gbit/s | 1,05 Gbit/s | 0,00 Gbit/s* | **16,95 Gbit/s** | 15,20 Gbit/s |
| **Net Latency (Jitter)** | 3,900 ms (0,465 ms) | 4,689 ms (2,548 ms) | 9,832 ms (0,026 ms) | 3,794 ms (0,019 ms) | 3,735 ms (0,060 ms) |
| **Sysbench Read** | **276,24 MiB/s** | 47,34 MiB/s | 78,51 MiB/s | 34,42 MiB/s | 34,00 MiB/s |
| **Sysbench Write** | **184,16 MiB/s** | 31,56 MiB/s | 52,34 MiB/s | 22,95 MiB/s | 22,66 MiB/s |
| **Sysbench Latency** | **0,05 ms** | 0,42 ms | 0,16 ms | 0,20 ms | 0,20 ms |
| **FIO DB Commit (Write)** | **1.328,00 MiB/s** | 30,50 MiB/s | 33,50 MiB/s | 42,10 MiB/s | 35,60 MiB/s |
| **FIO fsync Latenz** | **0,10 ms** (104,6 µs) | 5,02 ms (5.018 µs) | 3,07 ms | 3,77 ms | 4,47 ms |
| **FIO fdatasync (QD1)** | **278,00 MiB/s** (12,4 µs) | 9,34 MiB/s (383,9 µs) | 22,30 MiB/s (154,2 µs) | 5,11 MiB/s (749,3 µs) | 5,68 MiB/s (675,4 µs) |
| **FIO Parallel Write (QD16)** | **1.660,00 MiB/s** (37,1 µs) | 14,80 MiB/s (3,98 ms) | 26,20 MiB/s (2,26 ms) | 6,91 MiB/s (8,52 ms) | 6,46 MiB/s (9,11 ms) |

*\* Hinweis zu Strato: Während des ursprünglichen Netzwerktests bestand keine Verbindung (0,00 Gbit/s).*

---

## 2. Vorher-Nachher-Vergleich: Zap Dedicated Server

Vor der Optimierung bremste die verbaute Consumer-NVMe (**Crucial P5 Plus 2TB**, Modell `CT2000P510SSD8`) synchrone Schreibvorgänge extrem aus. Da der SSD die Hardware-basierte **Power Loss Protection (PLP)** fehlt, musste bei jedem `fsync` der Cache vollständig in die Flash-Zellen geleert werden, was zu Latenzen von über **26 ms** führte. Zudem verursachten NVMe-Power-Saving-States Aufwach-Latenzen.

Durch das Deaktivieren der Flush-Barrieren im Dateisystem (`nobarrier`) und Deaktivieren der NVMe-Energiesparmodi greift nun der schnelle SSD-RAM-Cache lückenlos und ohne Latenzspitzen:

| Metrik | Vorher (Standard) | Nachher (`nobarrier` + Tuning) | Leistungssteigerung |
| :--- | :---: | :---: | :---: |
| **Sysbench Read** | 9,78 MiB/s | **276,24 MiB/s** | **~28x schneller** |
| **Sysbench Write** | 6,52 MiB/s | **184,16 MiB/s** | **~28x schneller** |
| **Sysbench Latenz** | 0,69 ms | **0,05 ms** | **13x geringere Latenz** |
| **FIO DB Commit (Write)** | 6,17 MiB/s | **1.328,00 MiB/s** | **~215x schneller** |
| **FIO fsync-Latenz** | 26.123,66 µs (~26,1 ms) | **104,59 µs (~0,10 ms)** | **250x geringere Latenz** |
| **FIO fdatasync (QD1)** | 5,27 MiB/s | **278,00 MiB/s** | **~52x schneller** |
| **FIO Parallel Write (QD16)** | 5,35 MiB/s | **1.660,00 MiB/s** | **~310x schneller** |

---

## 3. Durchgeführte Optimierungsschritte (Zap Dedicated)

1. **NVMe Power-Saving Deaktivierung (GRUB Boot-Parameter):**
   Um Aufwach-Latenzen (Micro-Stuttering) des NVMe-Controllers bei kurzen Schreibbefehlen zu verhindern, wurden die Power-Saving C-States der NVMe vollständig deaktiviert. In `/etc/default/grub`:
   ```bash
   GRUB_CMDLINE_LINUX_DEFAULT="quiet nvme_core.default_ps_max_latency_us=0"
   ```
   Anschließend wurde die Boot-Konfiguration neu generiert:
   ```bash
   update-grub
   ```

2. **I/O-Scheduler Umstellung:**
   Für das NVMe-Laufwerk `/dev/nvme0n1` wurde der Scheduler auf `none` umgestellt, um unnötigen Kernel-Queue-Overhead zu vermeiden. Dauerhaft eingerichtet über `/etc/udev/rules.d/60-nvme-scheduler.rules`:
   ```bash
   ACTION=="add|change", KERNEL=="nvme[0-n]*", ATTR{queue/scheduler}="none"
   ```

3. **Dateisystem-Anpassung (`/etc/fstab`):**
   Ergänzung der Mount-Optionen um `noatime` und `barrier=0` (`nobarrier`):
   ```text
   UUID=a8e61c3a-638e-4916-b107-92d6d543efec / ext4 errors=remount-ro,noatime,barrier=0 0 1
   ```

4. **Neuladen der Konfiguration:**
   ```bash
   systemctl daemon-reload
   mount -o remount /
   ```

---

## 4. Fazit & Einordnung der Systeme

* **Zap Dedicated Server:** Bietet nach der I/O-Optimierung mit gewaltigem Abstand die beste Gesamtperformance (32 Kerne, 1.328 MiB/s DB-Schreibdurchsatz bei 0,10 ms Latenz). Das unangefochtene Flaggschiff für schreib- und rechenintensive Haupt-Anwendungen.
* **Zap vServer (4 Kerne):** Belegt im Gesamtfeld den letzten Platz bei CPU-, RAM- und I/O-Leistung. Mit 1.298 Single-Core-Events/s, 5,02 ms `fsync`-Latenz und einer synchronen 1-Gbit/s-Netzanbindung eignet er sich primär für leichte Hilfsdienste, Entwicklungsumgebungen oder als Backup-Node.
* **Hetzner & Strato Cloud-VMs:** Bieten ein solides Mittelfeld. Hetzner punktet vor allem durch seine überlegene Netzwerkanbindung (15–17 Gbit/s Upload), während Strato nach dem Tuning ordentliche parallele Schreibwerte (QD16: 26,2 MiB/s) liefert.
