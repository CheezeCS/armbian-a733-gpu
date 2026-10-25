# Fan (Orange Pi Zero 3W)

## Symptom

The fan on the 2-pin header spins for about a second at power-on and then never
again, however hot the board gets.

## Hardware

From the board schematic: the fan's `+` goes to `VCC-5V` through 1 ohm (R88);
its `-` is switched to ground by an N-MOSFET (Q2, WNM2021) whose gate is driven
through 10 kohm (R89) by `FAN_EN_PWM` = **PWM0 channel 5 on pin PD5**. There is
no pull-down on the gate, which is why the fan runs briefly at power-on before
the pin is configured.

The vendor device tree describes it as a `pwm-fan` on `pwm@2527000` channel 5,
40 kHz, cooling levels `0 50 102 170 255`, bound to the CPU zones' 55 C trip.
(Its `fan-supply` points at a 3.3 V PMIC switch that has nothing to do with this
fan; harmless.)

## What is actually happening

Measured on the board:

| Drive | Fan |
|---|---|
| PD5 forced high as a GPIO | spins |
| PWM 100% (constant high) | spins |
| PWM 90 / 67 / 40 / 20% at 40 kHz | does not start |
| PWM 50% at 100 Hz or 25 Hz | tries to start, stalls |
| 100% kick, then 70 / 50 / 35% at 100 Hz | stops after the kick |
| PWM 10 / 30 / 0% at 100 Hz (inversion check) | does not start |

The PWM block and the pinmux are fine (the vendor PWM driver switches PD5 to
`pwm0_5` itself when the channel is enabled, and back to an input with pull-down
when it is disabled). The fan simply cannot run on interrupted ground: it has
its own motor controller that resets whenever its supply is chopped. Typical for
small 2-wire fans; PWM speed control cannot work with this header, only on/off.

The vendor setup therefore never works: `step_wise` raises the fan one level at
a time from 0, and levels 1-3 never start it. On top of that, `step_wise` in
kernel 6.6 ignores trip hysteresis, so even a plain on/off level at a trip would
cycle every few seconds.

## Fix (verified)

1. `files/overlay/a733-fan.dts` (installed as `/boot/overlay-user/a733-fan.dtbo`,
   `user_overlays=a733-fan` in `/boot/armbianEnv.txt`):
   - `cooling-levels = <0 255>`: off or 100%;
   - the kernel's fan bindings are moved from the 55 C trips to the critical
     trips, so the thermal governor no longer drives the fan. CPU frequency
     throttling bindings are unchanged.
2. `a733-fan-control` + `a733-fan-control.service`: switches the fan on when the
   hottest of the CPU and GPU zones reaches 60 C and off at or below 50 C, after
   at least 30 s of running. Leaves the fan on if the service stops or fails.
   Thresholds in `/etc/default/a733-fan`.

Do **not** add a `pinctrl` property to the `pwm-fan` node: the vendor PWM driver
claims PD5 for the channel node when enabling it, the two devices conflict
("pin PD5 already requested by soc@3000000:pwm-fan") and pwm-fan fails to probe.

Result on the test board: under load on all 8 cores the fan switched on at
60 C and held the CPU at 61 C; after the load stopped it cooled to 50 C in about
10 s and switched off.

Images built with `build.sh` for `orangepizero3w` include all of this. On an
existing system:

```bash
sudo apt install device-tree-compiler
dtc -@ -I dts -O dtb -o a733-fan.dtbo files/overlay/a733-fan.dts
sudo install -D -m 644 a733-fan.dtbo /boot/overlay-user/a733-fan.dtbo
echo "user_overlays=a733-fan" | sudo tee -a /boot/armbianEnv.txt   # or extend an existing line
sudo install -m 755 files/fan/a733-fan-control /usr/local/sbin/
sudo install -m 644 files/fan/a733-fan-control.service /etc/systemd/system/
sudo systemctl enable a733-fan-control && sudo reboot
```
