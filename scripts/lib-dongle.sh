# RTL-SDR device helpers.
#
# Concatenated into the runnable scripts by the flake, so not executable alone.

# True when something already holds the RTL-SDR. Linux exposes raw USB under
# /dev/bus/usb; elsewhere we cannot tell, so report "not busy".
dongle_busy() {
  [ -d /dev/bus/usb ] || return 1
  lsof /dev/bus/usb/*/* 2>/dev/null \
    | grep -qiE 'rtl|2832|rtlsdr|readsb|dump1090'
}

require_free_dongle() {
  if dongle_busy; then
    echo "ERROR: the RTL-SDR is already in use."
    echo "Stop the running stack (or gqrx / sdrpp / another readsb) first."
    exit 1
  fi
}
