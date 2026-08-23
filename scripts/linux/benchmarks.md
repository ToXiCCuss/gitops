# Server-Vergleich: Hetzner (alt) vs. Zap vs. Strato vs. Hetzner (neu)

*Erstellt am 23.08.2026*

---

## CPU & RAM

| Metrik | Hetzner (alt) | Zap | Strato | Hetzner (neu) | Bewertung |
|---|---|---|---|---|---|
| CPU Performance | 1411,95 events/s | **2647,88 events/s** | 2014,40 events/s | 1707,92 events/s | Zap > Strato > Hetzner neu > Hetzner alt |
| RAM Write | 24.546 MiB/s | **42.037 MiB/s** | 32.815 MiB/s | 26.127 MiB/s | Zap > Strato > Hetzner neu > Hetzner alt |
| RAM Read | 41.076 MiB/s | **102.062 MiB/s** | 79.609 MiB/s | 60.882 MiB/s | Zap > Strato > Hetzner neu > Hetzner alt |

Der neue Hetzner-Server ist bei CPU/RAM spürbar stärker als der alte, bleibt aber unter Zap und Strato.

---

## Netzwerk

| Metrik | Hetzner (alt) | Zap | Strato | Hetzner (neu) | Bewertung |
|---|---|---|---|---|---|
| Download (typische Einzelmessungen) | ~700–1000 Mbit/s (schwankend) | ~250–400 Mbit/s (schwankend) | **~1,47–1,48 Gbit/s (sehr konstant)** | ~0,9–2,1 Gbit/s (schwankend, aber hoch) | Strato am konstantesten, Hetzner neu am höchsten im Peak |
| Download (Ausreißer letzte Messung) | 10,4 Gbit/s | 2,99 Gbit/s | 14,7 Gbit/s | 14,5 Gbit/s | ⚠️ vermutlich Loopback/lokal, nicht belastbar |
| Upload | fehlerhaft formatiert | fehlerhaft formatiert | fehlerhaft formatiert, mit 0-Werten | fehlerhaft formatiert, mit 0-Wert | ⚠️ bei allen vier nicht auswertbar |
| Latenz | 3,854 ms (Jitter 0,143 ms) | 3,460 ms (Jitter 0,088 ms) | 9,906 ms (Jitter 0,060 ms) | **3,720 ms (Jitter 0,037 ms)** | Hetzner neu hat den niedrigsten Jitter |

> ⚠️ **Hinweis:** Die Upload-Zeile ist bei **allen vier Reports** fehlerhaft formatiert (Zahl/Einheit vertauscht, z. B. "Gbits/sec 236") und enthält teils 0-Werte. Diese Messung sollte aus dem Vergleich gestrichen werden, bis das Benchmark-Skript korrigiert ist.

---

## Sysbench (Disk I/O, sequentiell)

| Metrik | Hetzner (alt) | Zap | Strato | Hetzner (neu) | Bewertung |
|---|---|---|---|---|---|
| Read | 30,80 MiB/s | 9,84 MiB/s | **78,25 MiB/s** | 47,15 MiB/s | Strato > Hetzner neu > Hetzner alt > Zap |
| Write | 20,53 MiB/s | 6,56 MiB/s | **52,17 MiB/s** | 31,43 MiB/s | Strato > Hetzner neu > Hetzner alt > Zap |
| Latenz | 0,26 ms | 0,69 ms | 0,20 ms | **0,14 ms** | Hetzner neu am niedrigsten |

---

## FIO – Random R/W 70/30 (Durchsatz nach Blockgröße)

| Blockgröße | Hetzner (alt) R/W | Zap R/W | Strato R/W | Hetzner (neu) R/W |
|---|---|---|---|---|
| 4k | 133 / 57,4 MiB/s (34,2k/14,7k IOPS) | 3272 / 1401 MiB/s (838k/359k IOPS) ⚠️ | 78,1 / 33,5 MiB/s (20,0k/8,6k IOPS) | **434 / 186 MiB/s (111k/47,7k IOPS)** |
| 64k | 1044 / 448 MiB/s (16,7k/7,2k IOPS) | 853 / 366 MiB/s (13,6k/5,9k IOPS) | 477 / 204 MiB/s (7,6k/3,3k IOPS) | **3944 / 1694 MiB/s (63,1k/27,1k IOPS)** |
| 512k | 1664 / 715 MiB/s (3,3k/1,4k IOPS) | 994 / 428 MiB/s (2,0k/0,9k IOPS) | 477 / 207 MiB/s (0,95k/0,4k IOPS) | **8177 / 3507 MiB/s (16,3k/7,0k IOPS)** |
| 1m | 1810 / 780 MiB/s (1,8k/0,8k IOPS) | 1107 / 481 MiB/s (1,1k/0,5k IOPS) | 477 / 209 MiB/s (0,47k/0,2k IOPS) | **8231 / 3526 MiB/s (8,2k/3,5k IOPS)** |

**Beobachtung:** Der neue Hetzner-Server dominiert klar ab 64k Blockgröße – 8,2 GiB/s Read bei 1M-Blöcken ist ein deutlicher Sprung gegenüber allen anderen (fast 4,5x schneller als der alte Hetzner-Server, ~7x schneller als Strato). Das deutet auf deutlich schnelleres NVMe-Storage hin.

> ⚠️ Der 4k-Wert von Zap (838k IOPS bei 118 µs Latenz) ist untypisch hoch für echten Disk-I/O – vermutlich Page-Cache-Effekte, keine reale Storage-Performance.

---

## FIO Sync 4k – fsync=1 (DB-Commit-Simulation)

*Dies ist der wichtigste Wert für Datenbank-Workloads mit synchronen Commits (z. B. PostgreSQL `synchronous_commit=on`, MySQL `innodb_flush_log_at_trx_commit=1`).*

| Metrik | Hetzner (alt) | Zap | Strato | Hetzner (neu) | Bewertung |
|---|---|---|---|---|---|
| Read | 56,3 MiB/s (14,4k IOPS) | 5,9 MiB/s (1516 IOPS) | 78,1 MiB/s (20,0k IOPS) | **189 MiB/s (48,4k IOPS)** | Hetzner neu klar vorne |
| Write | 24,2 MiB/s (6189 IOPS) | 2,5 MiB/s (651 IOPS) | 33,5 MiB/s (8588 IOPS) | **81,1 MiB/s (20,8k IOPS)** | Hetzner neu klar vorne |
| fsync-Latenz | 6,63 ms | 63,30 ms | 1,92 ms | **1,95 ms** | Strato und Hetzner neu nahezu gleichauf, beide sehr gut |

---

## Gesamtfazit

| Kategorie | Sieger |
|---|---|
| CPU / RAM (Rechenleistung) | **Zap** |
| Netzwerk-Latenz/Jitter | **Hetzner (neu)** |
| Netzwerk-Download (Peak) | **Hetzner (neu)** / Strato (konstanter) |
| Sequentielle Disk-I/O (Sysbench) | **Strato** |
| Große Blockgrößen (FIO 64k–1m) | **Hetzner (neu)** – mit großem Abstand |
| DB-Commit-Performance (IOPS/Durchsatz) | **Hetzner (neu)** |
| DB-Commit-Latenz (fsync) | Strato ≈ Hetzner (neu) |

### Einordnung

Der **neue Hetzner-Server** ist ein deutlicher Sprung gegenüber dem alten – er kombiniert solide CPU/RAM-Werte (zwar unter Zap, aber besser als der alte Hetzner) mit dem mit Abstand besten Storage-Subsystem im gesamten Vergleich, sowohl bei Durchsatz als auch bei der für Datenbanken kritischen fsync-Latenz.

**Empfehlung je nach Workload:**
- **Datenbank / I/O-intensive Anwendung:** Hetzner (neu) – beste Kombination aus IOPS, Durchsatz und niedriger fsync-Latenz.
- **CPU-/RAM-intensive Workloads** (Rendering, In-Memory-Caching, Berechnungen): Zap – stärkste Rohleistung, aber schwächstes Storage (fsync-Latenz von 63 ms ist für DB-Workloads problematisch).
- **Große sequentielle Transfers / Streaming:** Hetzner (neu) oder Hetzner (alt), je nach Blockgröße.
- **Stabile, vorhersehbare Netzwerkbandbreite:** Strato.

> ⚠️ Die Upload-Messwerte in allen vier Reports sind fehlerhaft formatiert und sollten vor einer endgültigen Entscheidung nicht berücksichtigt werden, bis das Benchmark-Skript korrigiert wurde.
