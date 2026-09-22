#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  LOADER SETUP - Termux Auto Setup + Menu
#  Host file ini di Vercel (static file), lalu jalankan di HP:
#    curl -sL https://<domain-vercel-kamu>/loader.sh -o loader.sh && bash loader.sh
# ============================================================

set -u

# ---------- KONFIGURASI (edit sesuai kebutuhan) ----------
ROBLOX_APK_URL="https://ISI-LINK-APK-ROBLOX-KAMU.apk"   # link download APK Roblox yang sudah kamu siapin
DOWNLOAD_DIR="$HOME/storage/downloads/RobloxLoader"      # folder simpan hasil download
CONFIG_DIR="$HOME/.config/loader"
CONFIG_FILE="$CONFIG_DIR/config.env"
MARKER_FILE="$CONFIG_DIR/.setup_done"
CLONE_WORKDIR="$HOME/.cache/loader_clone_work"
KEYSTORE_PATH="$CONFIG_DIR/clone.keystore"
CLONES_LIST="$CONFIG_DIR/clones.list"

# ---------- WARNA ----------
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"
C_RED="\033[1;31m"
C_BOLD="\033[1m"

log()  { echo -e "${C_CYAN}[*]${C_RESET} $1"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $1"; }
err()  { echo -e "${C_RED}[X]${C_RESET} $1"; }

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"
# muat config lama (kalau ada)
# shellcheck disable=SC1090
source "$CONFIG_FILE" 2>/dev/null || true

# ============================================================
# BAGIAN 1: AUTO SETUP (hanya jalan sekali)
# ============================================================
run_setup() {
    echo -e "${C_BOLD}=== AUTO SETUP TERMUX DIMULAI ===${C_RESET}"

    log "Update & upgrade package..."
    pkg update -y && pkg upgrade -y
    ok "pkg update & upgrade selesai"

    log "Minta izin storage (akan muncul popup izin, tekan Allow/Izinkan)..."
    termux-setup-storage
    sleep 2
    ok "Storage setup diminta"

    log "Install package yang benar-benar dipakai script ini..."
    pkg install -y curl termux-api unzip zip
    ok "curl, termux-api, unzip, zip terinstall"

    log "Install tools buat clone & sign APK (apktool, aapt, apksigner, java)..."
    pkg install -y openjdk-17 apktool aapt apksigner
    command -v zipalign >/dev/null 2>&1 || pkg install -y zipalign 2>/dev/null || true
    ok "tools clone/sign terinstall (atau sudah ada)"

    java -version >/dev/null 2>&1 && ok "Java (buat clone/sign) terdeteksi" || warn "Java belum kedetect, cek manual"

    mkdir -p "$DOWNLOAD_DIR"

    touch "$MARKER_FILE"
    echo -e "${C_GREEN}${C_BOLD}=== SETUP SELESAI ===${C_RESET}"
    sleep 1
}

# ============================================================
# BAGIAN 2: FITUR-FITUR MENU
# ============================================================

show_status() {
    clear
    echo -e "${C_BOLD}===== SYSTEM STATUS =====${C_RESET}"
    echo -e "${C_CYAN}Tanggal/Jam     :${C_RESET} $(date)"
    echo -e "${C_CYAN}Device (model)  :${C_RESET} $(getprop ro.product.model 2>/dev/null || echo 'tidak diketahui')"
    echo -e "${C_CYAN}Android SDK     :${C_RESET} $(getprop ro.build.version.sdk 2>/dev/null || echo '-')"
    echo -e "${C_CYAN}Termux storage  :${C_RESET}"
    df -h "$HOME" 2>/dev/null
    echo -e "${C_CYAN}Java (clone/sign):${C_RESET} $(java -version 2>&1 | head -1 || echo 'belum terinstall')"
    echo -e "${C_CYAN}apktool         :${C_RESET} $(command -v apktool >/dev/null 2>&1 && echo 'terinstall' || echo 'belum terinstall')"
    echo -e "${C_CYAN}Roblox packages :${C_RESET}"
    detect_roblox_packages | sed 's/^/    - /'
    echo "=========================="
    pause_back
}

is_root() {
    su -c id 2>/dev/null | grep -q 'uid=0'
}

# Deteksi package Roblox yang terinstall (ORI + clone), non-root dulu,
# fallback ke root kalau daftar kosong (beberapa device butuh root utk pm list)
detect_roblox_packages() {
    local out
    out="$(pm list packages 2>/dev/null)"
    if ! echo "$out" | grep -qi roblox; then
        if is_root; then
            out="$(su -c 'pm list packages' 2>/dev/null)"
        fi
    fi
    echo "$out" | grep -oi 'package:\S*roblox\S*' | sed 's/^package://' | sort -u
}

# Bangun deep-link roblox:// dari berbagai bentuk link private server
build_uri() {
    local link="$1"
    local code place

    if [[ "$link" =~ share\?code=([^\&]*) ]]; then
        code="${BASH_REMATCH[1]}"
        echo "roblox://navigation/share_links?code=${code}&type=Server"
        return
    fi

    if [[ "$link" =~ /games/([0-9]+) ]]; then
        place="${BASH_REMATCH[1]}"
    fi
    if [[ "$link" =~ privateServerLinkCode=([^\&]*) ]]; then
        code="${BASH_REMATCH[1]}"
    fi
    if [ -n "$place" ] && [ -n "$code" ]; then
        echo "roblox://placeId=${place}&linkCode=${code}"
        return
    fi

    # fallback: pakai link apa adanya (misal sudah berupa roblox://...)
    echo "$link"
}

is_pkg_alive() {
    local pkg="$1"
    pidof "$pkg" >/dev/null 2>&1 && return 0
    ps -A 2>/dev/null | grep -q "$pkg" && return 0
    return 1
}

# Minta user pilih 1 package Roblox dari daftar yang terdeteksi
pilih_akun() {
    local -a pkgs
    mapfile -t pkgs < <(detect_roblox_packages)

    if [ "${#pkgs[@]}" -eq 0 ]; then
        err "Tidak ada package Roblox terdeteksi di perangkat ini." >&2
        read -rp "Masukkan nama package manual (kosongkan buat batal): " manual >&2
        echo "$manual"
        return
    fi

    {
        echo -e "${C_GREEN}Ditemukan ${#pkgs[@]} package Roblox (ORI/clone):${C_RESET}"
        local i=1
        for p in "${pkgs[@]}"; do
            if [ "$p" = "com.roblox.client" ]; then
                echo -e "  ${C_CYAN}${i}.${C_RESET} ${p}  ${C_GREEN}[ORI]${C_RESET}"
            else
                echo -e "  ${C_CYAN}${i}.${C_RESET} ${p}  ${C_YELLOW}[CLONE]${C_RESET}"
            fi
            i=$((i + 1))
        done
        echo -e "  ${C_CYAN}0.${C_RESET} Kembali"
    } >&2

    read -rp "Pilih nomor akun: " pilihan >&2
    if [ "$pilihan" = "0" ] || [ -z "$pilihan" ]; then
        echo ""
        return
    fi
    if ! [[ "$pilihan" =~ ^[0-9]+$ ]] || [ "$pilihan" -lt 1 ] || [ "$pilihan" -gt "${#pkgs[@]}" ]; then
        err "Pilihan tidak valid." >&2
        echo ""
        return
    fi
    echo "${pkgs[$((pilihan - 1))]}"
}

join_private_server() {
    clear
    echo -e "${C_BOLD}===== JOIN PRIVATE SERVER =====${C_RESET}"

    log "Mendeteksi package Roblox terinstall..."
    local pkg
    pkg="$(pilih_akun)"
    if [ -z "$pkg" ]; then
        warn "Dibatalkan."
        pause_back
        return
    fi

    echo -e "Akun dipilih: ${C_GREEN}${pkg}${C_RESET}"
    read -rp "Tempel link private server (roblox://... / https://www.roblox.com/games/...?privateServerLinkCode=...): " link
    if [ -z "$link" ]; then
        warn "Link kosong, dibatalkan."
        pause_back
        return
    fi

    local uri
    uri="$(build_uri "$link")"

    log "Membuka ${pkg}..."
    if is_pkg_alive "$pkg"; then
        log "${pkg} sudah berjalan, kirim link langsung tanpa restart..."
    fi

    local output
    output="$(am start -a android.intent.action.VIEW -p "$pkg" -d "$uri" 2>&1)"

    if echo "$output" | grep -qi 'error\|exception'; then
        err "Gagal membuka aplikasi."
        echo -e "${C_YELLOW}${output}${C_RESET}"
    else
        ok "Berhasil membuka private server."
    fi

    pause_back
}

download_roblox() {
    clear
    echo -e "${C_BOLD}===== AUTO DOWNLOAD ROBLOX =====${C_RESET}"
    if download_roblox_file; then
        local target="$DOWNLOAD_DIR/roblox.apk"
        if command -v termux-open >/dev/null 2>&1; then
            log "Membuka installer APK..."
            termux-open "$target"
        else
            warn "termux-api belum terinstall, buka manual file di: $target"
        fi
    fi
    pause_back
}

disk_cleanup_menu() {
    clear
    echo -e "${C_BOLD}===== BERSIHKAN FILE SEMENTARA =====${C_RESET}"

    echo -e "${C_CYAN}Pemakaian disk saat ini:${C_RESET}"
    [ -d "$DOWNLOAD_DIR" ] && echo "  Download master APK : $(du -sh "$DOWNLOAD_DIR" 2>/dev/null | cut -f1)"
    [ -d "$CLONE_WORKDIR" ] && echo "  Folder clone/kerja  : $(du -sh "$CLONE_WORKDIR" 2>/dev/null | cut -f1)"
    echo ""

    echo "1) Hapus sisa folder decompile yang belum kehapus (aman, sisa proses gagal)"
    echo "2) Hapus semua APK clone hasil build (kamu bisa install ulang, tinggal rebuild dari menu Clone/Update)"
    echo "3) Hapus APK master yang udah didownload (roblox.apk)"
    echo "4) Hapus semuanya (folder kerja + APK clone + APK master)"
    echo "0) Kembali"
    read -rp "Pilih: " pilihan

    case "$pilihan" in
        1)
            find "$CLONE_WORKDIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} \; 2>/dev/null
            ok "Folder decompile sisa dibersihkan."
            ;;
        2)
            find "$CLONE_WORKDIR" -maxdepth 1 -name '*.apk' -delete 2>/dev/null
            ok "APK clone dibersihkan. (data package clone tetap ada di clones.list buat rebuild)"
            ;;
        3)
            rm -f "$DOWNLOAD_DIR/roblox.apk"
            ok "APK master dibersihkan."
            ;;
        4)
            rm -rf "$CLONE_WORKDIR"
            rm -f "$DOWNLOAD_DIR/roblox.apk"
            mkdir -p "$CLONE_WORKDIR" "$DOWNLOAD_DIR"
            ok "Semua file sementara dibersihkan."
            ;;
        0) return ;;
        *) warn "Pilihan tidak valid" ;;
    esac
    pause_back
}

pause_back() {
    echo ""
    read -rp "Tekan ENTER untuk kembali ke menu..." _
}

# Jalankan command di background sambil nampilin spinner + label, biar user
# tau proses lagi jalan (bukan hang) walau outputnya sendiri kita redam.
run_with_spinner() {
    local label="$1"
    shift
    local logfile
    logfile="$(mktemp)"

    "$@" >"$logfile" 2>&1 &
    local pid=$!
    local spin='|/-\'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r${C_CYAN}[*]${C_RESET} %s %s" "$label" "${spin:$i:1}"
        sleep 0.2
    done

    wait "$pid"
    local status=$?
    if [ "$status" -eq 0 ]; then
        printf "\r${C_GREEN}[OK]${C_RESET} %s          \n" "$label"
    else
        printf "\r${C_RED}[X]${C_RESET} %s - gagal          \n" "$label"
        echo -e "${C_YELLOW}--- log ---${C_RESET}"
        tail -n 15 "$logfile"
        echo -e "${C_YELLOW}-----------${C_RESET}"
    fi
    rm -f "$logfile"
    return "$status"
}

# ============================================================
# BAGIAN 2.5: CLONE ROBLOX (auto-sign, jumlah bebas) + AUTO UPDATE
# ============================================================

# Keystore dibuat sekali, dipakai buat semua clone (biar update APK-nya
# nanti dianggap "update" oleh Android, bukan install baru/conflict).
ensure_keystore() {
    if [ -f "$KEYSTORE_PATH" ]; then
        return
    fi
    log "Membuat keystore buat sign clone (sekali saja)..."
    local pass
    pass="$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    keytool -genkeypair -v \
        -keystore "$KEYSTORE_PATH" \
        -alias loaderclone \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$pass" -keypass "$pass" \
        -dname "CN=Loader, OU=Loader, O=Loader, L=City, S=State, C=ID" >/dev/null 2>&1

    grep -v '^KEYSTORE_PASS=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    echo "KEYSTORE_PASS=\"$pass\"" >> "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    KEYSTORE_PASS="$pass"
    ok "Keystore dibuat: $KEYSTORE_PATH"
}

get_apk_version() {
    aapt dump badging "$1" 2>/dev/null | grep -o "versionName='[^']*'" | sed "s/versionName='//;s/'//"
}

get_installed_version() {
    dumpsys package "$1" 2>/dev/null | grep -m1 'versionName=' | sed 's/.*versionName=//' | awk '{print $1}'
}

install_apk() {
    local apk="$1"
    if is_root; then
        log "Install (root): $(basename "$apk")"
        su -c "pm install -r '$apk'"
    else
        log "Buka installer buat: $(basename "$apk") (tap Install di layar)"
        termux-open "$apk"
        read -rp "Tekan ENTER kalau instalasi sudah selesai/di-tap..." _
    fi
}

# Decompile master APK -> ganti package name & authorities provider ->
# rebuild -> align -> sign. Hasil akhir: $out_apk siap install.
build_clone_apk() {
    local master_apk="$1" new_pkg="$2" out_apk="$3"
    local work="$CLONE_WORKDIR/$new_pkg"

    rm -rf "$work"
    echo -e "${C_CYAN}--- Clone ${new_pkg} ---${C_RESET}"

    run_with_spinner "[1/5] Decompile APK master..." apktool d -f -o "$work" "$master_apk" \
        || { err "apktool decode gagal"; return 1; }

    local manifest="$work/AndroidManifest.xml"
    if [ ! -f "$manifest" ]; then
        err "AndroidManifest.xml tidak ketemu hasil decompile"
        return 1
    fi

    local orig_pkg
    orig_pkg="$(grep -m1 -o 'package="[^"]*"' "$manifest" | sed 's/package="//;s/"//')"
    if [ -z "$orig_pkg" ]; then
        err "Gagal deteksi package asli dari manifest"
        return 1
    fi

    log "[2/5] Patch package name: $orig_pkg -> $new_pkg"
    sed -i "s/package=\"$orig_pkg\"/package=\"$new_pkg\"/" "$manifest"
    sed -i "s/android:authorities=\"$orig_pkg\([^\"]*\)\"/android:authorities=\"$new_pkg\1\"/g" "$manifest"

    run_with_spinner "[3/5] Build ulang APK clone..." apktool b "$work" -o "$work/build.apk" \
        || { err "apktool build gagal"; return 1; }

    local aligned="$work/aligned.apk"
    if command -v zipalign >/dev/null 2>&1; then
        run_with_spinner "[4/5] Align APK..." zipalign -f -p 4 "$work/build.apk" "$aligned" \
            || cp "$work/build.apk" "$aligned"
    else
        log "[4/5] zipalign gak ada, skip align (langsung pakai build.apk)"
        cp "$work/build.apk" "$aligned"
    fi

    run_with_spinner "[5/5] Sign APK clone..." apksigner sign --ks "$KEYSTORE_PATH" \
        --ks-pass "pass:$KEYSTORE_PASS" --key-pass "pass:$KEYSTORE_PASS" \
        --out "$out_apk" "$aligned"

    if [ ! -f "$out_apk" ]; then
        err "Sign gagal buat $new_pkg"
        return 1
    fi

    # Folder hasil decompile (smali+resource) udah gak kepake begitu APK
    # jadi ke-sign - dihapus sekarang biar gak numpuk disk tiap clone/update.
    rm -rf "$work"

    ok "Clone $new_pkg siap: $out_apk"
    return 0
}

clone_roblox() {
    clear
    echo -e "${C_BOLD}===== CLONE ROBLOX (auto-sign) =====${C_RESET}"

    local master="$DOWNLOAD_DIR/roblox.apk"
    if [ ! -f "$master" ]; then
        warn "APK master belum ada, download dulu (menu Auto Download Roblox)..."
        download_roblox_file || { pause_back; return; }
    fi

    ensure_keystore
    mkdir -p "$CLONE_WORKDIR"
    touch "$CLONES_LIST"

    local existing
    existing="$(wc -l < "$CLONES_LIST" | tr -d ' ')"

    read -rp "Mau bikin berapa clone? " jumlah
    if ! [[ "$jumlah" =~ ^[0-9]+$ ]] || [ "$jumlah" -lt 1 ]; then
        warn "Jumlah tidak valid."
        pause_back
        return
    fi

    local i newpkg outapk
    for ((i = 1; i <= jumlah; i++)); do
        local idx=$((existing + i))
        newpkg="com.roblox.clientc${idx}"
        outapk="$CLONE_WORKDIR/${newpkg}.apk"

        echo -e "${C_BOLD}===== Clone ${i}/${jumlah} =====${C_RESET}"
        if build_clone_apk "$master" "$newpkg" "$outapk"; then
            install_apk "$outapk"
            echo "$newpkg" >> "$CLONES_LIST"
            ok "Clone #$idx ($newpkg) selesai. (${i}/${jumlah})"
        else
            err "Clone #$idx gagal, lanjut ke berikutnya... (${i}/${jumlah})"
        fi
    done

    ok "Selesai bikin $jumlah clone."
    pause_back
}

# Helper: download master apk ke file tetap (dipisah dari fungsi menu
# download_roblox biar bisa dipanggil ulang dari update_all_roblox)
download_roblox_file() {
    if [[ "$ROBLOX_APK_URL" == *"ISI-LINK-APK-ROBLOX-KAMU"* ]]; then
        err "ROBLOX_APK_URL belum kamu isi di bagian atas script ini."
        return 1
    fi
    mkdir -p "$DOWNLOAD_DIR"
    local target="$DOWNLOAD_DIR/roblox.apk"
    log "Mengunduh APK dari: $ROBLOX_APK_URL"
    curl -L --fail --progress-bar -o "$target" "$ROBLOX_APK_URL" || { err "Download gagal."; return 1; }
    ok "Download selesai: $target"
    return 0
}

update_all_roblox() {
    clear
    echo -e "${C_BOLD}===== CEK & UPDATE ROBLOX (Original + Clone) =====${C_RESET}"

    log "Ambil APK terbaru dari ROBLOX_APK_URL..."
    if ! download_roblox_file; then
        pause_back
        return
    fi

    local master="$DOWNLOAD_DIR/roblox.apk"
    local new_ver installed_ver
    new_ver="$(get_apk_version "$master")"
    installed_ver="$(get_installed_version "com.roblox.client")"

    echo -e "Versi APK baru      : ${C_YELLOW}${new_ver:-tidak terdeteksi}${C_RESET}"
    echo -e "Versi Roblox ORI terpasang : ${C_YELLOW}${installed_ver:-belum terinstall}${C_RESET}"

    if [ -n "$new_ver" ] && [ "$new_ver" = "$installed_ver" ]; then
        ok "Roblox ORI sudah versi terbaru. Cek clone tetap dilanjut kalau ada perubahan file master."
    else
        log "Update Roblox ORI ke versi $new_ver..."
        install_apk "$master"
    fi

    ensure_keystore
    touch "$CLONES_LIST"
    if [ ! -s "$CLONES_LIST" ]; then
        warn "Belum ada clone tersimpan, skip update clone."
        pause_back
        return
    fi

    mkdir -p "$CLONE_WORKDIR"
    local total_clones
    total_clones="$(wc -l < "$CLONES_LIST" | tr -d ' ')"
    local pkg outapk n=0
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        n=$((n + 1))
        outapk="$CLONE_WORKDIR/${pkg}.apk"
        log "Update clone ${n}/${total_clones}: $pkg"
        if build_clone_apk "$master" "$pkg" "$outapk"; then
            install_apk "$outapk"
            ok "Clone $pkg ter-update. (${n}/${total_clones})"
        else
            err "Gagal update clone $pkg. (${n}/${total_clones})"
        fi
    done < "$CLONES_LIST"

    ok "Semua clone sudah dicek/di-update."
    pause_back
}

# ============================================================
# BAGIAN 2.6: MONITORING ROBLOX & AUTO CLEANER (ROOT)
# Support buka banyak akun Roblox sekaligus tetap ringan & gak gampang
# ke-kill sistem. TIDAK mengubah CPU governor (dihilangkan sesuai request).
# ============================================================

# Pilih banyak akun sekaligus: "1,3" / "1 2 4" / "all"
pilih_akun_multi() {
    local -a pkgs
    mapfile -t pkgs < <(detect_roblox_packages)

    if [ "${#pkgs[@]}" -eq 0 ]; then
        err "Tidak ada package Roblox terdeteksi." >&2
        return
    fi

    {
        echo -e "${C_GREEN}Ditemukan ${#pkgs[@]} package Roblox:${C_RESET}"
        local i=1
        for p in "${pkgs[@]}"; do
            echo -e "  ${C_CYAN}${i}.${C_RESET} ${p}"
            i=$((i + 1))
        done
        echo -e "  ${C_CYAN}0.${C_RESET} Kembali"
        echo -e "Contoh: 1,3  atau  1 2 4  atau ketik 'all'"
    } >&2

    read -rp "Pilih akun yang mau di-monitor: " pilihan >&2
    if [ -z "$pilihan" ] || [ "$pilihan" = "0" ]; then
        return
    fi

    if [ "$(echo "$pilihan" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
        printf '%s\n' "${pkgs[@]}"
        return
    fi

    local -a idxs
    IFS=', ' read -ra idxs <<< "$pilihan"
    local seen=" "
    local n
    for n in "${idxs[@]}"; do
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        [ "$n" -ge 1 ] && [ "$n" -le "${#pkgs[@]}" ] || continue
        case "$seen" in *" $n "*) continue ;; esac
        seen="$seen$n "
        echo "${pkgs[$((n - 1))]}"
    done
}

clean_ram() {
    su -c 'sync' >/dev/null 2>&1
    su -c 'echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1
    su -c 'echo 1 > /proc/sys/vm/compact_memory' >/dev/null 2>&1
}

clean_storage() {
    su -c 'pm trim-caches 2048M' >/dev/null 2>&1
    su -c 'rm -rf /cache/*' >/dev/null 2>&1
    su -c 'rm -rf /data/local/tmp/*' >/dev/null 2>&1
    su -c 'rm -rf /data/log/*' >/dev/null 2>&1
    su -c 'rm -rf /data/tombstones/*' >/dev/null 2>&1
    logcat -c >/dev/null 2>&1
}

battery_bypass() {
    local pkg
    for pkg in "$@"; do
        su -c "dumpsys deviceidle whitelist +$pkg" >/dev/null 2>&1
    done
}

clear_notifications() {
    su -c 'service call notification 1' >/dev/null 2>&1
    su -c 'service call statusbar 2' >/dev/null 2>&1
}

acquire_wakelock() {
    local out
    out="$(termux-wake-lock 2>&1)"
    if echo "$out" | grep -qi 'not found\|no such file\|command not found'; then
        warn "Wake-Lock: termux-wake-lock tidak ada (install app Termux:API)"
        return 1
    fi
    ok "Wake-Lock: aktif"
}

release_wakelock() {
    termux-wake-unlock >/dev/null 2>&1
}

set_standby_bucket_active() {
    local pkg total=0 success=0
    for pkg in "$@"; do
        total=$((total + 1))
        local out
        out="$(su -c "am set-standby-bucket $pkg active" 2>&1)"
        echo "$out" | grep -qi 'error\|exception\|unknown command' || success=$((success + 1))
    done
    echo "Standby Bucket: ${success}/${total} akun -> active"
}

lower_oom_priority() {
    local pkg total=0 success=0
    for pkg in "$@"; do
        local pids
        pids="$(pidof "$pkg" 2>/dev/null)"
        local pid
        for pid in $pids; do
            total=$((total + 1))
            local out
            out="$(su -c "echo -900 > /proc/${pid}/oom_score_adj" 2>&1)"
            echo "$out" | grep -qi 'read-only\|permission denied\|no such' || success=$((success + 1))
        done
    done
    if [ "$total" -eq 0 ]; then
        echo "OOM Priority: proses tidak ditemukan (akun belum jalan?)"
    else
        echo "OOM Priority: ${success}/${total} proses diturunkan"
    fi
}

check_internet_ok() {
    local out
    out="$(su -c 'ping -c 1 -W 2 1.1.1.1' 2>&1)"
    echo "$out" | grep -qi '1 packets received\|1 received\|0% packet loss'
}

get_mem_total_avail() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d %d", int(t/1024), int(a/1024)}' /proc/meminfo 2>/dev/null
}

send_webhook() {
    local msg="$1"
    [ -z "${WEBHOOK_URL:-}" ] && return
    local payload
    payload="$(printf '{"content":"%s"}' "$(echo "$msg" | sed 's/"/\\"/g')")"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 &
}

set_webhook_menu() {
    clear
    echo -e "${C_BOLD}===== SET WEBHOOK NOTIFIKASI (Discord) =====${C_RESET}"
    echo -e "Webhook saat ini: ${C_YELLOW}${WEBHOOK_URL:-belum diset}${C_RESET}"
    read -rp "Masukkan Discord webhook URL (kosongkan buat batal): " input
    if [ -z "$input" ]; then
        pause_back
        return
    fi
    if ! echo "$input" | grep -Eq '^https://(discord\.com|discordapp\.com)/api/webhooks/'; then
        err "URL tidak terlihat seperti Discord webhook yang valid."
        pause_back
        return
    fi
    grep -v '^WEBHOOK_URL=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    echo "WEBHOOK_URL=\"$input\"" >> "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    WEBHOOK_URL="$input"
    ok "Webhook tersimpan, mengirim pesan tes..."
    send_webhook "Webhook loader berhasil terhubung."
    pause_back
}

auto_cleaner() {
    clear
    echo -e "${C_BOLD}===== MONITORING ROBLOX & AUTO CLEANER (ROOT) =====${C_RESET}"

    if ! is_root; then
        err "Fitur ini butuh akses ROOT."
        pause_back
        return
    fi

    log "Mendeteksi & pilih akun Roblox yang mau di-monitor (bisa multi)..."
    local -a pkgs
    mapfile -t pkgs < <(pilih_akun_multi)
    if [ "${#pkgs[@]}" -eq 0 ]; then
        warn "Tidak ada akun dipilih, dibatalkan."
        pause_back
        return
    fi

    clear
    echo -e "${C_BOLD}Pilih fitur yang diaktifkan (akun terpilih: ${#pkgs[@]}):${C_RESET}"
    echo "1) RAM Cleanup (flush cache, aman buat app background)"
    echo "2) Storage Cleanup (cache, logs, temp files)"
    echo "3) Battery Bypass (whitelist dari Doze)"
    echo "4) Notification Clear"
    echo "5) Termux Wake-Lock (cegah deep sleep)"
    echo "6) App Standby Bucket -> Active (cegah throttle background)"
    echo "7) OOM Priority rendah (akun paling akhir dibunuh saat RAM penuh)"
    echo "8) Notifikasi Crash/Disconnect ke Webhook (notif only, tanpa auto-rejoin)"
    echo "all) Aktifkan semua fitur"
    read -rp "Pilih fitur (contoh: 1,3,5 atau 'all'): " featinput

    local -a FEATS
    if [ "$(echo "$featinput" | tr '[:upper:]' '[:lower:]')" = "all" ]; then
        FEATS=(1 2 3 4 5 6 7 8)
    else
        IFS=', ' read -ra FEATS <<< "$featinput"
    fi
    if [ "${#FEATS[@]}" -eq 0 ]; then
        warn "Tidak ada fitur dipilih, dibatalkan."
        pause_back
        return
    fi

    has_feat() {
        local f
        for f in "${FEATS[@]}"; do
            [ "$f" = "$1" ] && return 0
        done
        return 1
    }

    local ram_threshold=0
    if has_feat 1; then
        read -rp "RAM Cleanup cuma jalan kalau RAM tersisa di bawah berapa MB? [default 700]: " ram_threshold
        [[ "$ram_threshold" =~ ^[0-9]+$ ]] || ram_threshold=700
        log "RAM Cleanup: threshold ${ram_threshold}MB (skip kalau RAM masih aman, biar gak buang-buang cache yang lagi kepake Roblox)"
    fi

    read -rp "Interval cek dalam detik [default 30]: " interval
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=30
    if [ "$interval" -lt 10 ]; then
        warn "Interval di bawah 10 detik lumayan berat (Storage Cleanup/Standby Bucket/OOM jalan tiap siklus). Kalau device kerasa lag/panas, naikin intervalnya."
    fi

    if [ -z "${WEBHOOK_URL:-}" ]; then
        warn "Belum ada webhook diset, notifikasi tidak akan dikirim (atur di menu Set Webhook Notifikasi)."
    fi

    if has_feat 3; then log "Battery Bypass awal..."; battery_bypass "${pkgs[@]}"; ok "Battery bypass diterapkan"; fi
    if has_feat 5; then acquire_wakelock; fi
    if has_feat 6; then log "Set App Standby Bucket awal..."; set_standby_bucket_active "${pkgs[@]}"; fi

    clear
    echo -e "${C_BOLD}${C_GREEN}Monitoring aktif untuk ${#pkgs[@]} akun:${C_RESET}"
    printf '  - %s\n' "${pkgs[@]}"
    echo -e "${C_CYAN}Interval:${C_RESET} setiap ${interval} detik | ${C_YELLOW}Tekan Ctrl+C buat stop${C_RESET}"
    echo "=================================================="

    log "Webhook cuma dipakai buat notif status Roblox (app tertutup/jalan lagi, internet putus/nyambung)."

    declare -A prev_alive
    local p
    for p in "${pkgs[@]}"; do
        if is_pkg_alive "$p"; then prev_alive["$p"]=1; else prev_alive["$p"]=0; fi
    done
    local was_online=1
    check_internet_ok || was_online=0

    local clean_count=0
    local stop=0
    trap 'stop=1' INT

    while [ "$stop" -eq 0 ]; do
        sleep "$interval" &
        wait $! 2>/dev/null
        [ "$stop" -eq 1 ] && break

        clean_count=$((clean_count + 1))
        local ts results
        ts="$(date +%T)"
        results=""

        if has_feat 1; then
            local avail_now before after freed
            before=($(get_mem_total_avail))
            avail_now="${before[1]}"
            if [ "$avail_now" -lt "$ram_threshold" ]; then
                clean_ram
                after=($(get_mem_total_avail))
                freed=$((after[1] - avail_now))
                results="${results}RAM: ${avail_now}MB->dibersihin (+${freed}MB) | "
            else
                results="${results}RAM: ${avail_now}MB masih aman, skip | "
            fi
        fi
        if has_feat 2; then clean_storage; results="${results}Storage: cleaned | "; fi
        if has_feat 3; then battery_bypass "${pkgs[@]}"; fi
        if has_feat 4; then clear_notifications; results="${results}Notif: cleared | "; fi
        if has_feat 6; then results="${results}$(set_standby_bucket_active "${pkgs[@]}") | "; fi
        if has_feat 7; then results="${results}$(lower_oom_priority "${pkgs[@]}") | "; fi

        local alive_list=() dead_list=()
        for p in "${pkgs[@]}"; do
            if is_pkg_alive "$p"; then alive_list+=("$p"); else dead_list+=("$p"); fi
        done

        echo -e "${C_CYAN}[$ts] Clean #${clean_count}:${C_RESET} ${results%| }"
        [ "${#alive_list[@]}" -gt 0 ] && echo -e "  ${C_GREEN}Jalan:${C_RESET} ${alive_list[*]}"
        [ "${#dead_list[@]}" -gt 0 ] && echo -e "  ${C_YELLOW}Tidak terdeteksi:${C_RESET} ${dead_list[*]}"

        if has_feat 8; then
            local online=1
            check_internet_ok || online=0
            if [ "$was_online" -eq 1 ] && [ "$online" -eq 0 ]; then
                send_webhook "Internet terputus terdeteksi saat clean #${clean_count}."
            elif [ "$was_online" -eq 0 ] && [ "$online" -eq 1 ]; then
                send_webhook "Internet tersambung kembali saat clean #${clean_count}."
            fi
            was_online=$online

            for p in "${pkgs[@]}"; do
                local now=0
                is_pkg_alive "$p" && now=1
                local before_state="${prev_alive[$p]}"
                if [ "$before_state" -eq 1 ] && [ "$now" -eq 0 ]; then
                    send_webhook "App tertutup: ${p} (clean #${clean_count}). Perlu dibuka ulang manual."
                elif [ "$before_state" -eq 0 ] && [ "$now" -eq 1 ]; then
                    send_webhook "App kembali terdeteksi jalan: ${p} (clean #${clean_count})"
                fi
                prev_alive["$p"]=$now
            done
        fi

        if [ $((clean_count % 5)) -eq 0 ]; then
            : # ringkasan berkala dihapus - webhook cuma buat status Roblox, bukan aktivitas cleaner
        fi
    done

    trap - INT
    if has_feat 5; then release_wakelock; fi

    echo ""
    warn "Monitoring dihentikan. Total: ${clean_count}x clean"
    pause_back
}

# ============================================================
# BAGIAN 3: MENU UTAMA
# ============================================================
main_menu() {
    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}=============================="
        echo "        LOADER - MENU UTAMA"
        echo -e "==============================${C_RESET}"
        echo "1) System Status"
        echo "2) Join Private Server"
        echo "3) Auto Download Roblox"
        echo "4) Clone Roblox (auto-sign, jumlah bebas)"
        echo "5) Cek & Update Roblox (Original + Semua Clone)"
        echo "6) Monitoring Roblox & Auto Cleaner (Root)"
        echo "7) Set Webhook Notifikasi"
        echo "8) Bersihkan File Sementara (hemat disk)"
        echo "9) Jalankan ulang Auto Setup"
        echo "0) Keluar"
        echo -e "${C_CYAN}------------------------------${C_RESET}"
        read -rp "Pilih menu: " choice

        case "$choice" in
            1) show_status ;;
            2) join_private_server ;;
            3) download_roblox ;;
            4) clone_roblox ;;
            5) update_all_roblox ;;
            6) auto_cleaner ;;
            7) set_webhook_menu ;;
            8) disk_cleanup_menu ;;
            9) run_setup ;;
            0) echo "Sampai jumpa!"; exit 0 ;;
            *) warn "Pilihan tidak valid"; sleep 1 ;;
        esac
    done
}

# ============================================================
# ENTRY POINT
# ============================================================
if [ ! -f "$MARKER_FILE" ]; then
    run_setup
fi

main_menu
