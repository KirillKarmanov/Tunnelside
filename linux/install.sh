#!/bin/sh
# Tunnelside for Linux: sudo ./install.sh  (Ubuntu with GNOME; WireGuard wg0)
set -e
[ "$(id -u)" = 0 ] || { echo "Запустите через sudo: sudo ./install.sh"; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)
apt-get install -y -q python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 >/dev/null
install -d /opt/tunnelside/icons
install -m 755 "$SRC/tunnelsided.py" "$SRC/tunnelside-gui.py" "$SRC/tunnelside-cli.py" /opt/tunnelside/
install -m 644 "$SRC/tunnelside_common.py" /opt/tunnelside/
install -m 644 "$SRC"/icons/* /opt/tunnelside/icons/
ln -sf /opt/tunnelside/tunnelside-cli.py /usr/local/bin/tunnelside
install -m 644 "$SRC/tunnelsided.service" /etc/systemd/system/tunnelsided.service
install -m 644 "$SRC/io.github.kirillkarmanov.Tunnelside.desktop" /usr/share/applications/
sed 's#tunnelside-gui.py#tunnelside-gui.py --hidden#' "$SRC/io.github.kirillkarmanov.Tunnelside.desktop" > /etc/xdg/autostart/io.github.kirillkarmanov.Tunnelside.desktop
systemctl daemon-reload
systemctl enable tunnelsided >/dev/null 2>&1
systemctl restart tunnelsided
echo "Tunnelside установлен: служба tunnelsided, значок в панели после входа, команда tunnelside"
