#!/usr/bin/env bash
#
# io-optimize.sh
# ---------------------------------------------------------------------------
# I/O-Performance-Optimierung für Linux-Server (Datenbank-/Disk-Workloads)
#
# Basiert auf den im Benchmark-Bericht dokumentierten Schritten für den
# "Zap Dedicated Server" (NVMe Power-States, I/O-Scheduler, fstab-Optionen).
#
# WICHTIG - Bitte vor dem Ausführen lesen:
#   1) Dieses Skript ändert Boot-Parameter, den I/O-Scheduler und die
#      Mount-Optionen des Root-Dateisystems. Es MUSS mit root-Rechten
#      ausgeführt werden und erfordert für die GRUB-Änderung idealerweise
#      einen Reboot.
#   2) `nobarrier`/`barrier=0` deaktiviert die Journal-Schreibbarrieren des
#      Dateisystems. Das ist NUR dann sicher, wenn das Storage eine
#      hardwareseitige Power Loss Protection (PLP) besitzt (z.B. Enterprise-
#      NVMe/SSD mit Kondensator-Pufferung) ODER das System an einer
#      unterbrechungsfreien Stromversorgung (USV) hängt. Bei Consumer-SSDs
#      ohne PLP UND ohne USV kann ein Stromausfall zu Dateisystem- bzw.
#      Datenbank-Korruption führen. Das Skript fragt dies aktiv ab und
#      wendet die Option nur nach Bestätigung an.
#   3) Auf virtuellen Maschinen (Cloud-VMs, vServer) mit Netzwerk-Storage
#      als Backend bringen NVMe-Power-State- und Scheduler-Tuning in der
#      Regel NICHTS, da der Flaschenhals im Storage-Backend/Netzwerk liegt,
#      nicht im lokalen Kernel-I/O-Pfad. Das Skript erkennt virtualisierte
#      Umgebungen und überspringt dort die entsprechenden Schritte
#      automatisch (mit Hinweis).
#
# Nutzung:
#   sudo ./io-optimize.sh            # interaktiv, mit Rückfragen
#   sudo ./io-optimize.sh --dry-run  # nur anzeigen, nichts verändern
#
# ---------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# --- Hilfsfunktionen ---------------------------------------------------------

log()   { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[FEHLER]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }

run() {
    # Führt einen Befehl aus, oder zeigt ihn nur an im Dry-Run-Modus
    if $DRY_RUN; then
        echo "  (dry-run) $*"
    else
        eval "$@"
    fi
}

confirm() {
    # Fragt y/n ab, gibt 0 (true) bei "ja" zurück
    local prompt="$1"
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
    err "Bitte als root ausführen (sudo $0)."
    exit 1
fi

echo "==================================================================="
echo " I/O-Performance-Optimierung – Diagnose & Anwendung"
echo "==================================================================="
echo

# --- 1) Diagnose: virtualisierte Umgebung? -----------------------------------

log "Prüfe, ob es sich um eine virtuelle Maschine handelt..."
VIRT_TYPE="none"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT_TYPE=$(systemd-detect-virt || true)
fi

if [[ "$VIRT_TYPE" != "none" && -n "$VIRT_TYPE" ]]; then
    warn "Erkannte Virtualisierung: '$VIRT_TYPE'."
    warn "NVMe-Power-State- und Scheduler-Tuning wirken hier oft NICHT,"
    warn "wenn das Storage über das Hypervisor-/Cloud-Backend läuft"
    warn "(z.B. Netzwerk-Storage, Ceph, EBS-ähnliche Systeme)."
    warn "Hohe fsync/fdatasync-Latenzen (>10ms) deuten meist auf Storage-"
    warn "Backend- oder Netzwerklatenz hin, nicht auf lokale NVMe-Settings."
    echo
    if ! confirm "Trotzdem mit den NVMe-/Scheduler-Optimierungen fortfahren?"; then
        log "NVMe-/Scheduler-Schritte werden übersprungen."
        SKIP_NVME_TUNING=true
    else
        SKIP_NVME_TUNING=false
    fi
else
    ok "Keine Virtualisierung erkannt – Bare-Metal-System."
    SKIP_NVME_TUNING=false
fi
echo

# --- 2) Diagnose: Welches Laufwerk trägt das Root-Dateisystem? ---------------

log "Ermittle Root-Dateisystem und zugrundeliegendes Blockgerät..."
ROOT_SRC=$(findmnt -n -o SOURCE / || true)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE / || true)
log "Root-Partition: $ROOT_SRC (Dateisystem: $ROOT_FSTYPE)"

# Basisgerät ermitteln (z.B. nvme0n1p1 -> nvme0n1, sda1 -> sda)
ROOT_DISK=$(lsblk -no pkname "$ROOT_SRC" 2>/dev/null || true)
if [[ -z "$ROOT_DISK" ]]; then
    ROOT_DISK=$(basename "$ROOT_SRC" | sed -E 's/p?[0-9]+$//')
fi
log "Zugrundeliegendes Gerät: /dev/$ROOT_DISK"

IS_NVME=false
if [[ "$ROOT_DISK" == nvme* ]]; then
    IS_NVME=true
    ok "NVMe-Laufwerk erkannt."
else
    log "Kein NVMe-Laufwerk (evtl. virtio/SCSI-Blockgerät in einer VM)."
fi
echo

# --- 3) Diagnose: Power Loss Protection / USV abfragen -----------------------

echo "-------------------------------------------------------------------"
echo " Sicherheitsabfrage zu synchronen Schreiboperationen (nobarrier)"
echo "-------------------------------------------------------------------"
echo "Das Deaktivieren von Dateisystem-Barrieren (nobarrier) beschleunigt"
echo "fsync-lastige Workloads (z.B. Datenbanken) erheblich, ist aber nur"
echo "sicher bei:"
echo "  - Enterprise-SSD/NVMe MIT Power Loss Protection, ODER"
echo "  - Server an einer USV mit sauberem Shutdown bei Stromausfall"
echo
APPLY_NOBARRIER=false
if confirm "Ist eine der beiden Bedingungen (PLP-Hardware oder USV) erfüllt?"; then
    APPLY_NOBARRIER=true
else
    warn "nobarrier wird NICHT gesetzt, um Datenintegrität zu schützen."
fi
echo

# --- 4) NVMe Power-Saving deaktivieren (nur Bare-Metal + NVMe) ---------------

if [[ "$SKIP_NVME_TUNING" == false && "$IS_NVME" == true ]]; then
    log "Schritt 1/4: NVMe Power-Saving-Latenz per GRUB-Parameter deaktivieren..."
    GRUB_FILE="/etc/default/grub"
    PARAM="nvme_core.default_ps_max_latency_us=0"

    if [[ -f "$GRUB_FILE" ]]; then
        if grep -q "$PARAM" "$GRUB_FILE"; then
            ok "Parameter bereits vorhanden in $GRUB_FILE."
        else
            run "cp '$GRUB_FILE' '${GRUB_FILE}.bak.\$(date +%Y%m%d%H%M%S)'"
            run "sed -i -E 's/(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\\1 $PARAM\"/' '$GRUB_FILE'"
            ok "Parameter zu $GRUB_FILE hinzugefügt (Backup angelegt)."
        fi
        run "update-grub"
        REBOOT_REQUIRED=true
    else
        warn "$GRUB_FILE nicht gefunden – Schritt übersprungen (evtl. anderer Bootloader, z.B. systemd-boot)."
    fi
else
    log "Schritt 1/4 übersprungen (keine NVMe oder Virtualisierung ohne Bestätigung)."
fi
echo

# --- 5) I/O-Scheduler auf 'none' setzen (nur bei NVMe) -----------------------

if [[ "$SKIP_NVME_TUNING" == false && "$IS_NVME" == true ]]; then
    log "Schritt 2/4: I/O-Scheduler für /dev/$ROOT_DISK auf 'none' setzen..."
    UDEV_RULE="/etc/udev/rules.d/60-nvme-scheduler.rules"
    RULE_CONTENT='ACTION=="add|change", KERNEL=="nvme[0-n]*", ATTR{queue/scheduler}="none"'

    if [[ -f "$UDEV_RULE" ]] && grep -qF "$RULE_CONTENT" "$UDEV_RULE"; then
        ok "udev-Regel bereits vorhanden."
    else
        run "echo '$RULE_CONTENT' > '$UDEV_RULE'"
        ok "udev-Regel angelegt: $UDEV_RULE"
    fi
    run "udevadm control --reload-rules"
    run "udevadm trigger --subsystem-match=block"

    SCHED_PATH="/sys/block/$ROOT_DISK/queue/scheduler"
    if [[ -f "$SCHED_PATH" ]]; then
        run "echo none > '$SCHED_PATH'" || warn "Scheduler konnte nicht sofort live gesetzt werden (Regel greift beim nächsten Boot)."
    fi
else
    log "Schritt 2/4 übersprungen."
fi
echo

# --- 6) fstab anpassen: noatime (+ ggf. nobarrier) ---------------------------

log "Schritt 3/4: Mount-Optionen in /etc/fstab anpassen..."
FSTAB="/etc/fstab"
run "cp '$FSTAB' '${FSTAB}.bak.\$(date +%Y%m%d%H%M%S)'"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_SRC" 2>/dev/null || true)
if [[ -z "$ROOT_UUID" ]]; then
    warn "UUID für $ROOT_SRC konnte nicht ermittelt werden – bitte /etc/fstab manuell prüfen."
else
    log "Root-UUID: $ROOT_UUID"

    # Baue die gewünschte Optionsergänzung
    NEW_OPTS="noatime"
    if $APPLY_NOBARRIER; then
        NEW_OPTS="${NEW_OPTS},barrier=0"
    fi

    log "Aktuelle fstab-Zeile für /:"
    grep "$ROOT_UUID" "$FSTAB" || warn "Keine passende Zeile in $FSTAB gefunden."

    echo
    warn "Automatisches Editieren von /etc/fstab ist fehleranfällig (ein Tippfehler"
    warn "kann den Server beim nächsten Boot unbootbar machen). Daher hier die"
    warn "empfohlene Ziel-Zeile zur MANUELLEN Übernahme statt automatischem sed:"
    echo
    echo "  UUID=${ROOT_UUID} / ${ROOT_FSTYPE} errors=remount-ro,${NEW_OPTS} 0 1"
    echo
    if confirm "Soll ich versuchen, dies automatisch in $FSTAB zu setzen? (mit Backup)"; then
        run "sed -i -E \"s#(UUID=${ROOT_UUID}[[:space:]]+/[[:space:]]+${ROOT_FSTYPE}[[:space:]]+)[^[:space:]]+#\\1errors=remount-ro,${NEW_OPTS}#\" '$FSTAB'"
        ok "fstab aktualisiert. Backup liegt unter ${FSTAB}.bak.*"
    else
        log "Bitte die Zeile oben manuell in $FSTAB eintragen."
    fi
fi
echo

# --- 7) Konfiguration neu laden ----------------------------------------------

log "Schritt 4/4: Konfiguration neu laden..."
run "systemctl daemon-reload"

if ! $DRY_RUN; then
    if confirm "Root-Dateisystem jetzt remounten (mount -o remount /)?"; then
        run "mount -o remount /"
        ok "Remount durchgeführt."
    else
        warn "Bitte manuell 'mount -o remount /' ausführen oder rebooten, damit fstab-Änderungen greifen."
    fi
fi

echo
echo "==================================================================="
if [[ "${REBOOT_REQUIRED:-false}" == true ]]; then
    warn "Ein Reboot ist erforderlich, damit der GRUB-Parameter aktiv wird:"
    echo "    sudo reboot"
fi
echo
log "Empfehlung: Nach Anwendung / Reboot erneut benchmarken (z.B. sysbench,"
log "fio mit fsync=1) und die Werte mit den 'Vorher'-Werten vergleichen,"
log "um den tatsächlichen Effekt zu verifizieren."
echo "==================================================================="
