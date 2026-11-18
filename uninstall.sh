#!/usr/bin/env bash
# uninstall.sh — put the Pi back the way it was (desktop files only; no packages removed).
set -uo pipefail

TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SHARE=/usr/local/share/macpi
PREFIX=/usr/local/bin

say() { printf '  %s\n' "$*"; }

printf '==> Removing MacPi\n'

# stop the moving parts
pkill -f 'xwinwrap.*macpi' 2>/dev/null
pkill -f 'mpv.*livewall' 2>/dev/null
pkill -x tint2 2>/dev/null
pkill -x plank 2>/dev/null

say "session files"
sudo rm -f /etc/lightdm/lightdm.conf.d/60-macpi.conf
sudo rm -f /usr/share/applications/macpi-menu.desktop
sudo rm -f "$PREFIX/macpi-active-app" "$PREFIX/macpi-wallpaper" \
           "$PREFIX/macpi-remote" "$PREFIX/macpi-settings"
sudo rm -rf "$SHARE"
sudo rm -rf /usr/share/plank/themes/MacPi

say "autostart entries"
for f in macpi-menubar macpi-dock macpi-wallpaper macpi-tray macpi-services \
         xfce4-panel xfdesktop; do
  rm -f "$TARGET_HOME/.config/autostart/$f.desktop"
done

say "themes and configs (WhiteSur themes are left in place)"
rm -rf "$TARGET_HOME/.config/macpi"
rm -f  "$TARGET_HOME/.config/tint2/macpi-tint2rc"
rm -f  "$TARGET_HOME/.local/share/rofi/themes/macpi.rasi"
rm -rf "$TARGET_HOME/.config/plank/dock1"
for c in xsettings xfwm4 xfce4-keyboard-shortcuts; do
  rm -f "$TARGET_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/$c.xml"
done

say "IR keytable service"
if [[ -f /etc/systemd/system/macpi-ir.service ]]; then
  sudo systemctl disable --now macpi-ir.service 2>/dev/null
  sudo rm -f /etc/systemd/system/macpi-ir.service /etc/rc_keymaps/macpi-roku
  sudo systemctl daemon-reload
fi

cat <<'EOF'

  Done. Reboot and the Pi will autologin to whatever session lightdm
  has left, or to a plain console if this was a Lite image.

  To get the stock panel back, delete the Hidden=true overrides:
      rm -f ~/.config/autostart/xfce4-panel.desktop
EOF
