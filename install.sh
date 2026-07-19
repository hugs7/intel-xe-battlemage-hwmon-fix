#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
	echo "install.sh: must run as root" >&2
	exit 1
fi

install -d /var/lib/b70-xe-hwmon /usr/local/sbin \
	/etc/kernel/postinst.d /etc/kernel/header_postinst.d
install -m 0644 "$repo_dir/xe-hwmon-battlemage-telemetry.patch" \
	/var/lib/b70-xe-hwmon/xe-hwmon-battlemage-telemetry.patch
install -m 0644 "$repo_dir/xe-hwmon-battlemage-forcewake-7.0.patch" \
	/var/lib/b70-xe-hwmon/xe-hwmon-battlemage-forcewake-7.0.patch
install -m 0755 "$repo_dir/scripts/b70-xe-rebuild" /usr/local/sbin/b70-xe-rebuild
install -m 0755 "$repo_dir/scripts/b70-xe-kernel-hook" \
	/etc/kernel/postinst.d/b70-xe-hwmon
install -m 0755 "$repo_dir/scripts/b70-xe-kernel-hook" \
	/etc/kernel/header_postinst.d/b70-xe-hwmon

echo "Installed b70-xe-hwmon hooks; rebuilds run when matching kernels or headers are installed."
