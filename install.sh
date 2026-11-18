#!/usr/bin/env bash
#
# MacPi — a clean, macOS-flavoured desktop for Raspberry Pi
# ---------------------------------------------------------
# Turns Raspberry Pi OS (Lite or Desktop, Bookworm or newer) into a single
# user, auto-login XFCE desktop with a macOS menubar, dock, Spotlight and an
# optional live wallpaper.
#
#   ./install.sh                 full install, defaults
#   ./install.sh --accent teal   pick the WhiteSur accent colour
#   ./install.sh --no-livewall   skip mpv/xwinwrap (lighter, no video)
#   ./install.sh --static-only   alias for --no-livewall
#   ./install.sh --scale 1.5     Xft DPI boost for a TV / large monitor
#   ./install.sh --offline       skip GitHub theme cloning (plain Adwaita look)
#   ./install.sh --dry-run       print the plan, change nothing
#
set -euo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- args
ACCENT="blue"
LIVEWALL=1
SCALE=""
OFFLINE=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accent)       ACCENT="${2:?}"; shift 2 ;;
    --no-livewall|--static-only) LIVEWALL=0; shift ;;
    --scale)        SCALE="${2:?}"; shift 2 ;;
    --offline)      OFFLINE=1; shift ;;
    --dry-run)      DRY=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- pretty
if [[ -t 1 ]]; then
  B=$'\033[1m'; BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YEL=$'\033[1;33m'
  RED=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
else
  B=""; BLUE=""; GREEN=""; YEL=""; RED=""; DIM=""; R=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$R" "$B" "$*" "$R"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$R" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$R" "$*"; }
die()  { printf '\n  %s✗ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
run()  { if (( DRY )); then printf '  %s[dry]%s %s\n' "$DIM" "$R" "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- context
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-${USER}}"
if [[ "$TARGET_USER" == "root" ]]; then
  die "run this as your normal user (it calls sudo itself)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "cannot resolve home for $TARGET_USER"
PREFIX="/usr/local"
SHARE="/usr/local/share/macpi"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

as_user() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then "$@"; else sudo -u "$TARGET_USER" -H "$@"; fi
}

# ---------------------------------------------------------------- preflight
step "Preflight"
[[ "$(uname -s)" == "Linux" ]] || die "this installer only runs on Linux (Raspberry Pi OS)"

MODEL="unknown Pi"
if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' < /proc/device-tree/model)"
elif [[ -r /sys/firmware/devicetree/base/model ]]; then
  MODEL="$(tr -d '\0' < /sys/firmware/devicetree/base/model)"
fi
info "board:   $MODEL"
info "arch:    $(uname -m)"
info "distro:  $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
info "user:    $TARGET_USER ($TARGET_HOME)"

command -v apt-get >/dev/null || die "apt-get not found — Raspberry Pi OS / Debian expected"
sudo -n true 2>/dev/null || { info "sudo password may be required"; }

PI_GEN=""
case "$MODEL" in
  *"Raspberry Pi 5"*)  PI_GEN=5 ;;
  *"Raspberry Pi 4"*)  PI_GEN=4 ;;
  *"Raspberry Pi 3"*)  PI_GEN=3 ;;
  *"Raspberry Pi 2"*)  PI_GEN=2 ;;
  *"Raspberry Pi Zero 2"*) PI_GEN="zero2" ;;
  *"Raspberry Pi Zero"*)   PI_GEN="zero" ;;
esac
if [[ -z "$PI_GEN" ]]; then warn "unrecognised board — continuing with safe defaults"; fi
if [[ "$PI_GEN" == "3" || "$PI_GEN" == "zero2" || "$PI_GEN" == "zero" ]]; then
  warn "$MODEL is a light board: live wallpaper will be capped to 720p and 24 fps"
fi

if (( DRY )); then
  step "Dry run"
  info "would install the desktop stack, themes, dock, menubar and (livewall=$LIVEWALL) wallpaper"
  info "nothing was changed"
  exit 0
fi

# ---------------------------------------------------------------- packages
step "Installing packages"
PKGS=(
  xserver-xorg xinit x11-xserver-utils dbus-x11
  lightdm xfce4-session xfwm4 xfce4-settings xfce4-power-manager
  thunar thunar-volman tumbler gvfs
  xfce4-terminal xdotool xinput wmctrl unclutter libnotify-bin
  tint2 plank rofi feh
  network-manager-gnome pasystray blueman policykit-1-gnome
  fonts-inter fonts-noto-color-emoji
  git curl ca-certificates
)
(( OFFLINE )) || PKGS+=(sassc libglib2.0-dev-bin)
if (( LIVEWALL )); then PKGS+=(mpv build-essential libx11-dev libxext-dev libxrender-dev); fi
PKGS+=(ir-keytable)

sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PKGS[@]}" \
  || die "package install failed"
ok "${#PKGS[@]} packages ready"

# ---------------------------------------------------------------- themes
THEME_NAME="Adwaita"
ICON_NAME="Adwaita"
CURSOR_NAME="default"
XFWM_THEME="Default"

if (( OFFLINE )); then
  warn "offline mode: keeping Adwaita (no WhiteSur theme)"
else
  step "Installing WhiteSur theme (macOS look)"
  GTK_DIR="$TARGET_HOME/.themes"
  ICON_DIR="$TARGET_HOME/.icons"
  as_user mkdir -p "$GTK_DIR" "$ICON_DIR"

  clone() {  # clone <repo> <dir>
    rm -rf "${TMP:?}/$2"
    git clone --depth=1 --quiet "https://github.com/vinceliuice/$1.git" "$TMP/$2" \
      || { warn "could not clone $1 — skipping"; return 1; }
  }

  if clone WhiteSur-gtk-theme whitesur; then
    info "building GTK / xfwm4 theme (this takes a few minutes on a Pi)"
    ( cd "$TMP/whitesur" && as_user ./install.sh -d "$GTK_DIR" -c dark -t "$ACCENT" ) \
      && ok "GTK theme installed" || warn "WhiteSur GTK build failed — staying on Adwaita"
  fi

  if clone WhiteSur-icon-theme whitesur-icons; then
    ( cd "$TMP/whitesur-icons" && as_user ./install.sh -d "$ICON_DIR" ) \
      && ok "icon theme installed" || warn "icon theme install failed"
  fi

  if clone WhiteSur-cursors whitesur-cursors; then
    if [[ -d "$TMP/whitesur-cursors/dist" ]]; then
      for d in "$TMP"/whitesur-cursors/dist/*; do
        as_user cp -r "$d" "$ICON_DIR/"
      done
      ok "cursor theme installed"
    else
      ( cd "$TMP/whitesur-cursors" && as_user ./install.sh ) \
        && ok "cursor theme built" || warn "cursor theme install failed"
    fi
  fi

  # pick whatever the builds actually produced
  pick() {  # pick <candidate...> <dir>
    local dir="${*: -1}" c
    for c in "${@:1:$#-1}"; do [[ -e "$dir/$c" ]] && { echo "$c"; return; }; done
  }
  THEME_NAME="$(pick WhiteSur-Dark MacOS-Dark Adwaita "$GTK_DIR")"
  XFWM_THEME="$(pick WhiteSur-Dark MacOS-Dark Default "$GTK_DIR")"
  ICON_NAME="$(pick WhiteSur-dark WhiteSur WhiteSur-light Adwaita "$ICON_DIR")"
  for c in WhiteSur-cursors MacOS-cursors; do
    [[ -e "$ICON_DIR/$c" ]] && { CURSOR_NAME="$c"; break; }
  done
  info "theme=$THEME_NAME icons=$ICON_NAME cursor=$CURSOR_NAME"
fi

# ---------------------------------------------------------------- files
step "Installing MacPi files"
run sudo mkdir -p "$SHARE/wallpapers" "$SHARE/livewall" "$PREFIX/bin" /usr/share/applications
run sudo cp "$SRC"/assets/wallpapers/*.jpg "$SHARE/wallpapers/"
for s in macpi-active-app macpi-wallpaper macpi-remote macpi-settings; do
  run sudo install -m 0755 "$SRC/scripts/$s" "$PREFIX/bin/$s"
done
run sudo install -m 0644 "$SRC/assets/icons/macpi-menu.png" "$SHARE/macpi-menu.png"

# apple menu button -> Spotlight
sudo tee /usr/share/applications/macpi-menu.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Spotlight
Comment=Search apps, files and windows
Exec=rofi -show drun -theme macpi
Icon=/usr/local/share/macpi/macpi-menu.png
Terminal=false
Categories=System;
StartupNotify=false
EOF
ok "launchers installed"

# ---------------------------------------------------------------- media
if (( LIVEWALL )); then
  step "Installing live wallpapers"
  if compgen -G "$SRC/assets/livewall/*.mp4" >/dev/null; then
    run sudo cp "$SRC"/assets/livewall/*.mp4 "$SHARE/livewall/"
    run bash -c "sudo cp '$SRC'/assets/livewall/*.jpg '$SHARE/livewall/' 2>/dev/null || true"
    ok "$(ls -1 "$SRC"/assets/livewall/*.mp4 | wc -l) clips copied"
  else
    warn "no clips in assets/livewall — run tools/render_livewall.py first"
  fi

  step "Building xwinwrap (draws video on the desktop)"
  if command -v xwinwrap >/dev/null; then
    ok "xwinwrap already present"
  else
    ( git clone --depth=1 --quiet https://github.com/ujjwal96/xwinwrap.git "$TMP/xwinwrap" \
      && cd "$TMP/xwinwrap" \
      && make >/dev/null 2>&1 \
      && sudo install -m 0755 xwinwrap "$PREFIX/bin/" ) \
      && ok "xwinwrap built" \
      || warn "xwinwrap build failed — live wallpaper will fall back to a still image"
  fi
fi

# ---------------------------------------------------------------- look
step "Writing desktop configuration"
XF_CONF="$TARGET_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
AUTOSTART="$TARGET_HOME/.config/autostart"
GTK3="$TARGET_HOME/.config/gtk-3.0"
GTK4="$TARGET_HOME/.config/gtk-4.0"
as_user mkdir -p "$XF_CONF" "$AUTOSTART" "$GTK3" "$GTK4" "$TARGET_HOME/.config/plank/dock1/launchers"

DPI=96
if [[ -n "$SCALE" ]]; then
  DPI=$(awk -v s="$SCALE" 'BEGIN{printf "%d", 96*s}')
fi

# --- GTK settings (what CSD apps and libadwaita read)
as_user tee "$GTK3/settings.ini" >/dev/null <<EOF
[Settings]
gtk-theme-name=$THEME_NAME
gtk-icon-theme-name=$ICON_NAME
gtk-cursor-theme-name=$CURSOR_NAME
gtk-cursor-theme-size=24
gtk-font-name=Inter 10
gtk-decoration-layout=close,minimize,maximize:
gtk-application-prefer-dark-theme=1
gtk-enable-animations=1
gtk-menu-images=1
gtk-button-images=1
gtk-primary-button-warps-slider=1
EOF

as_user tee "$GTK4/gtk.css" >/dev/null <<EOF
/* MacPi: pull the WhiteSur look into libadwaita apps */
@import url("file://$TARGET_HOME/.themes/$THEME_NAME/gtk-4.0/gtk.css");
EOF

# --- xsettings channel (fonts, cursors, theme for the session)
as_user tee "$XF_CONF/xsettings.xml" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$THEME_NAME"/>
    <property name="IconThemeName" type="string" value="$ICON_NAME"/>
    <property name="CursorThemeName" type="string" value="$CURSOR_NAME"/>
    <property name="CursorThemeSize" type="int" value="24"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Inter 10"/>
    <property name="MonospaceFontName" type="string" value="Noto Sans Mono 10"/>
    <property name="CursorBlink" type="bool" value="true"/>
    <property name="CursorBlinkTime" type="uint" value="1200"/>
    <property name="DecorationLayout" type="string" value="close,minimize,maximize:"/>
    <property name="MenuImages" type="bool" value="true"/>
    <property name="ButtonImages" type="bool" value="true"/>
    <property name="EnableAnimations" type="bool" value="true"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="$DPI"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="int" value="1"/>
  </property>
</channel>
EOF

# --- xfwm4: traffic lights on the LEFT, compositing on for dock transparency
as_user tee "$XF_CONF/xfwm4.xml" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$XFWM_THEME"/>
    <property name="title_font" type="string" value="Inter SemiBold 10"/>
    <property name="title_alignment" type="string" value="center"/>
    <property name="button_layout" type="string" value="CHM|O"/>
    <property name="use_compositing" type="bool" value="true"/>
    <property name="show_frame_shadow" type="bool" value="true"/>
    <property name="show_popup_shadow" type="bool" value="true"/>
    <property name="sync_to_vblank" type="bool" value="true"/>
    <property name="frame_opacity" type="int" value="100"/>
    <property name="inactive_opacity" type="int" value="100"/>
    <property name="move_opacity" type="int" value="100"/>
    <property name="resize_opacity" type="int" value="100"/>
    <property name="popup_opacity" type="int" value="95"/>
    <property name="workspace_count" type="int" value="1"/>
    <property name="scroll_workspaces" type="bool" value="false"/>
    <property name="snap_to_border" type="bool" value="true"/>
    <property name="snap_to_windows" type="bool" value="true"/>
    <property name="snap_width" type="int" value="12"/>
    <property name="tile_on_move" type="bool" value="true"/>
    <property name="wrap_windows" type="bool" value="false"/>
    <property name="click_to_focus" type="bool" value="true"/>
    <property name="double_click_action" type="string" value="maximize"/>
    <property name="raise_on_focus" type="bool" value="true"/>
    <property name="box_move" type="bool" value="false"/>
    <property name="box_resize" type="bool" value="false"/>
    <property name="workspace_names" type="array">
      <value type="string" value="Desktop"/>
    </property>
  </property>
</channel>
EOF

# --- keyboard shortcuts (Spotlight on Super+Space, Terminal, screenshots)
as_user tee "$XF_CONF/xfce4-keyboard-shortcuts.xml" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-keyboard-shortcuts" version="1.0">
  <property name="commands" type="empty">
    <property name="custom" type="empty">
      <property name="&lt;Super&gt;space" type="string" value="rofi -show drun -theme macpi"/>
      <property name="&lt;Super&gt;d" type="string" value="rofi -show window -theme macpi"/>
      <property name="&lt;Super&gt;Return" type="string" value="xfce4-terminal"/>
      <property name="&lt;Super&gt;e" type="string" value="thunar"/>
      <property name="&lt;Super&gt;l" type="string" value="xflock4"/>
      <property name="&lt;Primary&gt;&lt;Alt&gt;t" type="string" value="xfce4-terminal"/>
    </property>
  </property>
</channel>
EOF

# --- plank dock
as_user cp "$SRC/config/plank/settings" "$TARGET_HOME/.config/plank/dock1/settings"
sudo mkdir -p /usr/share/plank/themes/MacPi
sudo cp "$SRC/config/plank/macpi-dock.theme" /usr/share/plank/themes/MacPi/dock.theme
for app in thunar xfce4-terminal firefox; do
  df=""
  for cand in "/usr/share/applications/$app.desktop" \
              "/usr/share/applications/org.xfce.$app.desktop"; do
    [[ -f "$cand" ]] && { df="$cand"; break; }
  done
  [[ -n "$df" ]] || continue
  as_user tee "$TARGET_HOME/.config/plank/dock1/launchers/$(basename "$df").dockitem" >/dev/null <<EOF
[PlankItem]
Launcher=file://$df
EOF
done
ok "dock pinned"

# --- tint2 menubar
as_user mkdir -p "$TARGET_HOME/.config/tint2"
as_user cp "$SRC/config/tint2/tint2rc" "$TARGET_HOME/.config/tint2/macpi-tint2rc"

# --- rofi theme
as_user mkdir -p "$TARGET_HOME/.local/share/rofi/themes"
as_user cp "$SRC/config/rofi/macpi.rasi" "$TARGET_HOME/.local/share/rofi/themes/macpi.rasi"

# --- autostart
mk_autostart() {  # mk_autostart <file> <name> <exec> [delay]
  local delay="${4:-0}"
  as_user tee "$AUTOSTART/$1" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=$delay
OnlyShowIn=XFCE;
NoDisplay=false
EOF
}
mk_autostart macpi-menubar.desktop "MacPi Menubar" "tint2 -c $TARGET_HOME/.config/tint2/macpi-tint2rc" 1
mk_autostart macpi-dock.desktop    "MacPi Dock"    "plank" 2
mk_autostart macpi-wallpaper.desktop "MacPi Wallpaper" "macpi-wallpaper start" 1
mk_autostart macpi-tray.desktop    "MacPi Tray"    "sh -c 'nm-applet --indicator & pasystray & blueman-applet &'" 3
mk_autostart macpi-services.desktop "MacPi Services" "sh -c 'unclutter -idle 3 -root &'" 2

# stock panel and desktop manager must stay out of the way
for d in xfce4-panel xfdesktop; do
  as_user tee "$AUTOSTART/$d.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=$d (disabled by MacPi)
Hidden=true
EOF
done
ok "autostart configured"

# ---------------------------------------------------------------- session
step "Configuring auto-login session"
sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/60-macpi.conf >/dev/null <<EOF
[Seat:*]
autologin-user=$TARGET_USER
autologin-user-timeout=0
user-session=xfce
session-wrapper=/etc/X11/Xsession
allow-guest=false
EOF

if systemctl list-unit-files | grep -q '^lightdm.service'; then
  run sudo systemctl enable lightdm
  run sudo systemctl set-default graphical.target
  ok "lightdm enabled (auto-login as $TARGET_USER into XFCE/X11)"
else
  warn "lightdm unit not found — check /etc/lightdm/lightdm.conf.d/60-macpi.conf"
fi

# ---------------------------------------------------------------- done
step "Done — MacPi $VERSION"
cat <<EOF

  Board      : $MODEL
  Theme      : $THEME_NAME   Icons: $ICON_NAME   Cursor: $CURSOR_NAME
  Live wall  : $([[ $LIVEWALL == 1 ]] && echo "on (macpi-wallpaper start)" || echo "off")
  Menubar    : tint2 (top)   Dock: plank (bottom)   Spotlight: Super+Space

  Reboot into it:
      sudo reboot

  Handy commands:
      macpi-wallpaper list | set aurora-lake | mode live|static | stop
      macpi-settings                     wallpaper + appearance panel
      macpi-remote detect                what input hardware is present
      macpi-remote learn-ir              map an IR remote (Roku simple remote)

  Recovery if the session misbehaves: Ctrl+Alt+F2, log in, run
      ./uninstall.sh

EOF
