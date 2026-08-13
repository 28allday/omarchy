# The Acer Nitro ANV14-61 is not in acer-wmi's DMI quirk table (kernel 7.2), so
# the driver loads without its Predator v4 interface. The Turbo key does
# nothing, the acer hwmon fan sensor is missing, and platform_profile offers
# low-power, balanced and performance only. With predator_v4=1 the key works,
# fan2_input appears, and quiet and balanced-performance join the profiles.
#
# Models the kernel does list get predator_v4 already, and forcing the option on
# them replaces their quirks with fewer ones, so omarchy-hw-acer-predator-v4
# matches exact product names only. Any existing predator_v4 line, active or
# commented out, is the user's choice and is left alone.
conf=/etc/modprobe.d/acer-wmi.conf

if omarchy-hw-acer-predator-v4 &&
  modinfo -p acer_wmi 2>/dev/null | grep '^predator_v4:' >/dev/null &&
  ! grep -qs 'predator_v4' "$conf"; then
  echo "Detected an Acer laptop the kernel does not list; enabling acer_wmi predator_v4"

  mkdir -p /etc/modprobe.d
  cat >>"$conf" <<'CONF'

# This model is missing from acer-wmi's DMI quirk table. Without the Predator v4
# interface its Turbo key, fan sensor and quiet/balanced-performance profiles
# are unavailable.
options acer_wmi predator_v4=1
CONF
fi
