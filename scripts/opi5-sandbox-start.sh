#!/bin/sh
set -eu

modprobe gpio_button || true

/usr/local/bin/blinky -D -c gpiochip1 -l 1 -i 250 &
exec /usr/local/bin/button
