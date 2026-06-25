#!/bin/bash
# omarchy-deck — install Steam Deck mode during the (offline) Omarchy chroot install.
#
# Run by install/post-install/all.sh via `run_logged`, patched to run BEFORE post-install/
# pacman.sh — that script swaps /etc/pacman.conf from the install-time [offline] repo to the
# ONLINE Omarchy repos, after which `pacman -S` finds NO packages offline. Running first keeps
# the offline repo active so the deck packages install from the baked mirror.
#
# Deck SYSTEM files are installed from a VENDORED rootfs tree via `sudo install`, NOT heredocs.
# Heredocs (`sudo tee <<EOF` / `cat <<EOF`) deliver EMPTY content here: the big `sudo pacman -S`
# that runs first uses a pty (modern sudo), which disrupts bash's fork-based heredoc writer for
# the rest of the script, so every subsequent heredoc yields a 0-byte file. `sudo install` of a
# real file has no stdin and works reliably (proven by the settings-TUI binary). The file bodies
# live under extras/omarchy-deck/rootfs/<abs-path> with modes in rootfs.manifest.
#
# HARD RULE: never abort the Omarchy install. Every step is guarded; the script always exits 0.

log() { echo "[omarchy-deck] $*"; }
warn() { echo "[omarchy-deck] WARN: $*"; }

# --- Resolve the real install user / home -----------------------------------------------
DECK_USER="${SUDO_USER:-$USER}"
DECK_HOME="$(getent passwd "$DECK_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$DECK_HOME" ]] && DECK_HOME="$HOME"
log "target user: $DECK_USER  home: $DECK_HOME"

DECK_EXTRAS="${OMARCHY_PATH:-$DECK_HOME/.local/share/omarchy}/extras/omarchy-deck"
DECK_ROOTFS="$DECK_EXTRAS/rootfs"
DECK_MANIFEST="$DECK_EXTRAS/rootfs.manifest"

# ========================================================================================
# 1. PACKAGES — from the baked offline mirror (no network, no AUR build, no prompts)
# ========================================================================================
deck_packages=(
  # session framework (pre-built AUR, in offline mirror)
  gamescope-session-git gamescope-session-steam-git
  # core steam runtime + base
  steam vulkan-icd-loader lib32-vulkan-icd-loader mesa lib32-mesa mesa-utils
  lib32-glibc lib32-gcc-libs lib32-libx11 lib32-libxss lib32-alsa-plugins
  lib32-libpulse lib32-openal lib32-nss lib32-libcups lib32-sdl2-compat
  lib32-freetype2 lib32-fontconfig lib32-libnm networkmanager gamemode
  lib32-gamemode ttf-liberation xdg-user-dirs kbd
  # runtime
  gamescope mangohud lib32-mangohud python python-evdev libcap curl pciutils
  ntfs-3g xcb-util-cursor udisks2
  # settings TUI deps
  gum jq
  # GPU userspace (all vendors — target hardware unknown at build time)
  vulkan-tools vulkan-mesa-layers
  nvidia-utils lib32-nvidia-utils nvidia-settings libva-nvidia-driver
  vulkan-radeon lib32-vulkan-radeon libvdpau lib32-libvdpau xf86-video-amdgpu
  vulkan-intel lib32-vulkan-intel intel-media-driver
)
log "installing ${#deck_packages[@]} deck packages from offline mirror..."
if omarchy-pkg-add "${deck_packages[@]}"; then
  log "deck packages installed"
else
  warn "some deck packages failed (offline mirror gap?) — continuing; deck mode may be partial"
fi

# Gate the rest on the session framework actually being present — without it there is no
# Gaming Mode to wire up, and we must not leave a dead launcher behind.
if ! pacman -Q gamescope-session-steam-git &>/dev/null; then
  warn "gamescope-session-steam-git not installed — skipping deck wiring (no launcher will be created)"
  exit 0
fi

# ========================================================================================
# 2. GPU DETECTION — lspci reads real host PCI (bind-mounted into the chroot)
# ========================================================================================
gpu_line="$(/usr/bin/lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)"
has_nvidia=false; has_amd=false; has_intel=false
echo "$gpu_line" | grep -qi nvidia && has_nvidia=true
echo "$gpu_line" | grep -iqE 'amd|radeon|advanced micro' && has_amd=true
echo "$gpu_line" | grep -qi intel && has_intel=true
log "GPU: nvidia=$has_nvidia amd=$has_amd intel=$has_intel"

# ========================================================================================
# 3. SYSTEM FILES — install from the vendored rootfs tree (manifest: "<mode> <abs-path>")
# ========================================================================================
if [[ -f "$DECK_MANIFEST" && -d "$DECK_ROOTFS" ]]; then
  installed=0
  while read -r mode path; do
    [[ -z "$mode" || -z "$path" ]] && continue
    src="$DECK_ROOTFS$path"
    if [[ -f "$src" ]]; then
      if sudo install -D -m "$mode" "$src" "$path"; then
        installed=$((installed + 1))
      else
        warn "failed to install $path"
      fi
    else
      warn "vendored file missing: $src"
    fi
  done < "$DECK_MANIFEST"
  log "installed $installed deck system files from vendored rootfs"
else
  warn "vendored rootfs/manifest missing at $DECK_EXTRAS — deck wiring incomplete"
fi

# NVIDIA gamescope env — only on NVIDIA (GBM_BACKEND=nvidia-drm would break AMD/Intel).
nvidia_env="$DECK_ROOTFS/etc/environment.d/90-nvidia-gamescope.conf"
if $has_nvidia && [[ -f "$nvidia_env" ]]; then
  sudo install -D -m 644 "$nvidia_env" /etc/environment.d/90-nvidia-gamescope.conf \
    && log "installed NVIDIA gamescope env"
fi

# SDDM session-switch config — dynamic (autologin user), written via printf (not a heredoc).
# The "zz-" prefix makes this autologin config win; gaming-session-switch toggles Session=.
autologin_user="$DECK_USER"
if [[ -f /etc/sddm.conf.d/autologin.conf ]]; then
  u="$(sed -n 's/^User=//p' /etc/sddm.conf.d/autologin.conf 2>/dev/null | head -1)"
  [[ -n "$u" ]] && autologin_user="$u"
fi
sddm_tmp="$(mktemp)"
printf '[Autologin]\nUser=%s\nSession=hyprland-uwsm\nRelogin=true\n' "$autologin_user" > "$sddm_tmp"
sudo install -D -m 644 "$sddm_tmp" /etc/sddm.conf.d/zz-gaming-session.conf \
  && log "wrote SDDM gaming session config (autologin: $autologin_user)"
rm -f "$sddm_tmp"

# ========================================================================================
# 4. SETTINGS TUI binary — from the vendored omarchy-deck (the monitor/res/refresh picker).
#    Its Walker entry ("Game Mode Setting") ships in the rootfs manifest above.
# ========================================================================================
if [[ -f "$DECK_EXTRAS/bin/omarchy-deck-settings" ]]; then
  sudo install -D -m 0755 "$DECK_EXTRAS/bin/omarchy-deck-settings" /usr/local/bin/omarchy-deck-settings \
    && log "installed Game Mode Setting TUI binary"
else
  warn "settings TUI not found at $DECK_EXTRAS/bin — skipping"
fi

# ========================================================================================
# 5. USER-OWNED CONFIG (written as $DECK_USER — runs as the install user; echo/printf only) -
# ========================================================================================

# --- gamescope-session-plus.conf — NO baked OUTPUT_CONNECTOR / resolution (auto) --------
# Monitor/resolution/refresh are intentionally NOT set: there is no live Hyprland in the
# chroot to detect them, and a static connector goes stale on laptops/docks. gamescope
# auto-picks the connected output at launch; the user refines via the settings TUI.
env_dir="$DECK_HOME/.config/environment.d"
mkdir -p "$env_dir"
gs_conf="$env_dir/gamescope-session-plus.conf"
{
  echo "STEAM_ALLOW_DRIVE_UNMOUNT=1"
  echo "FCITX_NO_WAYLAND_DIAGNOSE=1"
  echo "SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0"
  if $has_nvidia; then
    nv_id="$(/usr/bin/lspci -nn 2>/dev/null | grep -i nvidia | grep -oP '\[10de:\K[0-9a-fA-F]+' | head -1)"
    [[ -n "$nv_id" ]] && echo "VULKAN_ADAPTER=10de:${nv_id}"
    echo "GBM_BACKEND=nvidia-drm"
  elif $has_amd && ! $has_nvidia; then
    echo "ADAPTIVE_SYNC=1"
    echo "ENABLE_GAMESCOPE_HDR=1"
  fi
} > "$gs_conf"
log "wrote $gs_conf (auto output — pick a monitor via 'Game Mode Setting')"

# --- fcitx silence (env.d) --------------------------------------------------------------
fcitx_conf="$env_dir/90-fcitx-wayland.conf"
[[ -f "$fcitx_conf" ]] || echo "FCITX_NO_WAYLAND_DIAGNOSE=1" > "$fcitx_conf"

# --- Hyprland keybind Super+Shift+S → switch-to-gaming ----------------------------------
hypr_bindings="$DECK_HOME/.config/hypr/bindings.conf"
if [[ -f "$hypr_bindings" ]]; then
  if ! grep -q "switch-to-gaming" "$hypr_bindings" 2>/dev/null; then
    printf '\nbindd = SUPER SHIFT, S, Game Mode, exec, /usr/local/bin/switch-to-gaming\n' >> "$hypr_bindings"
    log "added Super+Shift+S keybind to bindings.conf"
  fi
else
  warn "bindings.conf not found at $hypr_bindings — Super+Shift+S not added (launcher still works)"
fi

# --- Elephant/Walker: launch desktop apps via uwsm-app (so the .desktop launches cleanly)
elephant_cfg="$DECK_HOME/.config/elephant/desktopapplications.toml"
if [[ -f "$elephant_cfg" ]] && command -v uwsm-app >/dev/null 2>&1; then
  if grep -q '^launch_prefix[[:space:]]*=' "$elephant_cfg" 2>/dev/null; then
    grep -q '^launch_prefix[[:space:]]*=[[:space:]]*"uwsm-app --"' "$elephant_cfg" 2>/dev/null \
      || sed -i 's|^launch_prefix[[:space:]]*=.*|launch_prefix = "uwsm-app --"|' "$elephant_cfg"
  else
    echo 'launch_prefix = "uwsm-app --"' >> "$elephant_cfg"
  fi
fi

# ========================================================================================
# 6. GROUPS + CAPS (chroot-safe; takes effect on first boot) -----------------------------
# ========================================================================================
if sudo usermod -aG video,input "$DECK_USER" 2>/dev/null; then
  log "added $DECK_USER to video,input"
else
  warn "could not add $DECK_USER to video,input — Gaming Mode may fail to switch (sudoers %video)"
fi
if command -v gamescope >/dev/null 2>&1; then
  sudo setcap 'cap_sys_nice=eip' "$(command -v gamescope)" 2>/dev/null \
    && log "granted cap_sys_nice to gamescope"
fi

# ========================================================================================
# 7. DEAD-LAUNCHER GUARD — never leave "Game Mode" pointing at a missing switch-to-gaming.
# ========================================================================================
gm_desktop=/usr/share/applications/omarchy-deck-gaming-mode.desktop
if [[ -f "$gm_desktop" && ! -x /usr/local/bin/switch-to-gaming ]]; then
  sudo rm -f "$gm_desktop"
  warn "switch-to-gaming missing — removed Game Mode launcher to avoid a dead entry"
fi

command -v update-desktop-database >/dev/null 2>&1 \
  && sudo update-desktop-database /usr/share/applications 2>/dev/null || true

# ========================================================================================
# 8. UPDATE CHANNEL — repoint the installed Omarchy repo at UPSTREAM so the system updates
#    and switches branches (master/rc/dev) exactly like a stock Omarchy install.
#
#    As shipped, ~/.local/share/omarchy is a copy of our fork clone: origin=28allday/omarchy
#    on branch "omarchy-deck". Left that way, `omarchy-update` pulls our force-rebuilt fork
#    branch (diverged history → broken update) and `omarchy-branch-set dev|rc` fails (the fork
#    has no such branches; HEAD isn't even master). The deck layer is already installed to the
#    system as real files above, so it persists regardless of the repo's git state.
#
#    Everything here is LOCAL / offline-safe. The base commit our build sits on is a real
#    basecamp/omarchy commit (sync-fork builds the branch on upstream/master and stamps it),
#    so `reset --hard` to it yields a pristine-upstream tree. The dev/rc remote-tracking refs
#    populate on the user's first online fetch via the all-branches refspec.
# ========================================================================================
OMARCHY_REPO_DIR="${OMARCHY_PATH:-$DECK_HOME/.local/share/omarchy}"
if [[ -d "$OMARCHY_REPO_DIR/.git" ]]; then
  # Preserve the manual re-run / --verify tool before the reset prunes it from the repo tree.
  if [[ -d "$DECK_EXTRAS" ]]; then
    cp -a "$DECK_EXTRAS" "$DECK_HOME/.local/share/omarchy-deck" 2>/dev/null \
      && log "preserved deck re-run tool at ~/.local/share/omarchy-deck"
  fi

  base=""
  [[ -f "$DECK_EXTRAS/upstream-base.commit" ]] \
    && base="$(tr -dc '0-9a-f' < "$DECK_EXTRAS/upstream-base.commit")"

  if git -C "$OMARCHY_REPO_DIR" remote set-url origin https://github.com/basecamp/omarchy.git; then
    git -C "$OMARCHY_REPO_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    log "repointed omarchy origin → basecamp/omarchy (upstream)"
  else
    warn "could not repoint omarchy origin — omarchy-update will still target the fork"
  fi

  if [[ -n "$base" ]] && git -C "$OMARCHY_REPO_DIR" reset --hard "$base" >/dev/null 2>&1; then
    log "reset omarchy repo to pristine upstream base ${base:0:12}"
  else
    warn "no/invalid upstream-base stamp — skipped pristine reset (origin still repointed)"
  fi

  # Make HEAD a real 'master' branch tracking origin/master, like a stock install.
  git -C "$OMARCHY_REPO_DIR" branch -M master 2>/dev/null || true
  git -C "$OMARCHY_REPO_DIR" config branch.master.remote origin
  git -C "$OMARCHY_REPO_DIR" config branch.master.merge refs/heads/master
  log "update channel = upstream master (omarchy-update / omarchy-branch-set now work)"
else
  warn "omarchy repo not a git checkout at $OMARCHY_REPO_DIR — update channel not repointed"
fi

log "deck layer install complete"
exit 0
