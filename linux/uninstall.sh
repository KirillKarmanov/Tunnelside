#!/bin/sh
set -e
[ "$(id -u)" = 0 ] || { echo "Запустите через sudo"; exit 1; }
systemctl disable --now tunnelsided 2>/dev/null || true
rm -f /etc/systemd/system/tunnelsided.service /usr/local/bin/tunnelside \
  /usr/share/applications/io.github.kirillkarmanov.Tunnelside.desktop /etc/xdg/autostart/io.github.kirillkarmanov.Tunnelside.desktop
rm -rf /opt/tunnelside
systemctl daemon-reload
echo "Tunnelside удалён (список правил остался в /var/lib/tunnelside)"
