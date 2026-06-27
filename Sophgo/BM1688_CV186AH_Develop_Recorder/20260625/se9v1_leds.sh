#!/bin/sh

RUN_LED="/sys/class/leds/se9v1:green:run"
STATUS_LED="/sys/class/leds/se9v1:green:status"
RUN_INTERVAL="${RUN_INTERVAL:-1}"
ACTIVE_LOW="${ACTIVE_LOW:-0}"

ADC_CHANNEL="${ADC_CHANNEL:-2}"
ADC_REF_MV="${ADC_REF_MV:-1800}"
ADC_MAX_RAW="${ADC_MAX_RAW:-4095}"
LOW_MAX_MV="${LOW_MAX_MV:-3700}"
FULL_MIN_MV="${FULL_MIN_MV:-4200}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
VBAT_SCALE_NUM="${VBAT_SCALE_NUM:-7}"
VBAT_SCALE_DEN="${VBAT_SCALE_DEN:-3}"
BAT_CAL_LOW_MV="${BAT_CAL_LOW_MV:-3700}"
BAT_CAL_LOW_RAW="${BAT_CAL_LOW_RAW:-}"
BAT_CAL_FULL_MV="${BAT_CAL_FULL_MV:-4200}"
BAT_CAL_FULL_RAW="${BAT_CAL_FULL_RAW:-}"

BAT_LOW_LED="/sys/class/leds/battery:red:low"
BAT_MID_LED="/sys/class/leds/battery:blue:mid"
BAT_FULL_LED="/sys/class/leds/battery:green:full"

RUN_PID=""
BAT_PID=""

wait_path()
{
	path="$1"
	i=0

	while [ "$i" -lt 10 ]; do
		[ -d "$path" ] && return 0
		i=$((i + 1))
		sleep 1
	done

	echo "se9v1_leds: missing $path" >&2
	return 1
}

wait_all_leds()
{
	wait_path "$RUN_LED" &&
	wait_path "$STATUS_LED" &&
	wait_path "$BAT_LOW_LED" &&
	wait_path "$BAT_MID_LED" &&
	wait_path "$BAT_FULL_LED"
}

set_led()
{
	led="$1"
	value="$2"

	if [ "$ACTIVE_LOW" = "1" ]; then
		if [ "$value" = "0" ]; then
			value=1
		else
			value=0
		fi
	fi

	[ -w "$led/trigger" ] && echo none > "$led/trigger"
	echo "$value" > "$led/brightness"
}

set_run_leds_off()
{
	set_led "$RUN_LED" 0
	set_led "$STATUS_LED" 0
}

set_battery_level()
{
	level="$1"

	case "$level" in
		low)
			set_led "$BAT_LOW_LED" 1
			set_led "$BAT_MID_LED" 0
			set_led "$BAT_FULL_LED" 0
			;;
		mid)
			set_led "$BAT_LOW_LED" 0
			set_led "$BAT_MID_LED" 1
			set_led "$BAT_FULL_LED" 0
			;;
		full)
			set_led "$BAT_LOW_LED" 0
			set_led "$BAT_MID_LED" 0
			set_led "$BAT_FULL_LED" 1
			;;
		off)
			set_led "$BAT_LOW_LED" 0
			set_led "$BAT_MID_LED" 0
			set_led "$BAT_FULL_LED" 0
			;;
	esac
}

read_adc_raw()
{
	for dev in /sys/bus/iio/devices/iio:device*; do
		[ -d "$dev" ] || continue

		raw="$dev/in_voltage${ADC_CHANNEL}_raw"
		if [ -r "$raw" ]; then
			[ -w "$raw" ] && echo 1 > "$raw"
			cat "$raw"
			return 0
		fi
	done

	return 1
}

read_adc_mv()
{
	for dev in /sys/bus/iio/devices/iio:device*; do
		[ -d "$dev" ] || continue

		input="$dev/in_voltage${ADC_CHANNEL}_input"
		if [ -r "$input" ]; then
			cat "$input"
			return 0
		fi

		raw="$dev/in_voltage${ADC_CHANNEL}_raw"
		scale="$dev/in_voltage${ADC_CHANNEL}_scale"
		[ -r "$scale" ] || scale="$dev/in_voltage_scale"
		if [ -r "$raw" ] && [ -r "$scale" ]; then
			[ -w "$raw" ] && echo 1 > "$raw"
			awk -v raw="$(cat "$raw")" -v scale="$(cat "$scale")" \
				'BEGIN { printf "%d\n", raw * scale }'
			return 0
		fi

		if [ -r "$raw" ]; then
			[ -w "$raw" ] && echo 1 > "$raw"
			awk -v raw="$(cat "$raw")" -v ref="$ADC_REF_MV" -v max="$ADC_MAX_RAW" \
				'BEGIN { printf "%d\n", raw * ref / max }'
			return 0
		fi
	done

	return 1
}

read_battery_mv()
{
	if [ -n "$BAT_CAL_LOW_RAW" ] && [ -n "$BAT_CAL_FULL_RAW" ]; then
		raw="$(read_adc_raw)" || return 1
		den=$((BAT_CAL_FULL_RAW - BAT_CAL_LOW_RAW))
		[ "$den" -ne 0 ] || return 1
		echo $((BAT_CAL_LOW_MV + (raw - BAT_CAL_LOW_RAW) * (BAT_CAL_FULL_MV - BAT_CAL_LOW_MV) / den))
		return 0
	fi

	adc_mv="$(read_adc_mv)" || return 1
	echo $((adc_mv * VBAT_SCALE_NUM / VBAT_SCALE_DEN))
}

battery_level_from_mv()
{
	vbat_mv="$1"

	if [ "$vbat_mv" -le "$LOW_MAX_MV" ]; then
		echo low
	elif [ "$vbat_mv" -ge "$FULL_MIN_MV" ]; then
		echo full
	else
		echo mid
	fi
}

run_led_loop()
{
	while true; do
		set_led "$RUN_LED" 1
		set_led "$STATUS_LED" 0
		sleep "$RUN_INTERVAL"

		set_led "$RUN_LED" 0
		set_led "$STATUS_LED" 1
		sleep "$RUN_INTERVAL"
	done
}

battery_led_loop()
{
	modprobe soph_saradc >/dev/null 2>&1 || true

	while true; do
		vbat_mv="$(read_battery_mv)"
		if [ -z "$vbat_mv" ]; then
			echo "se9v1_leds: ADC${ADC_CHANNEL} read failed" >&2
			set_battery_level off
		else
			set_battery_level "$(battery_level_from_mv "$vbat_mv")"
		fi

		sleep "$POLL_INTERVAL"
	done
}

cleanup()
{
	[ -n "$RUN_PID" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
	[ -n "$BAT_PID" ] && kill "$BAT_PID" >/dev/null 2>&1 || true
	set_run_leds_off
	set_battery_level off
}

start_leds()
{
	wait_all_leds || exit 1
	trap cleanup INT TERM EXIT

	run_led_loop &
	RUN_PID="$!"
	battery_led_loop &
	BAT_PID="$!"

	wait "$RUN_PID" "$BAT_PID"
}

show_status()
{
	led="$1"

	echo "$led:"
	printf "  trigger: "
	cat "$led/trigger"
	printf "  brightness: "
	cat "$led/brightness"
}

show_all_status()
{
	wait_all_leds || exit 1
	show_status "$RUN_LED"
	show_status "$STATUS_LED"
	show_status "$BAT_LOW_LED"
	show_status "$BAT_MID_LED"
	show_status "$BAT_FULL_LED"

	vbat_mv="$(read_battery_mv)" || return 0
	level="$(battery_level_from_mv "$vbat_mv")"
	echo "battery=${vbat_mv}mV level=${level} low=3400-3700mV mid=3800-4100mV full=4200-4400mV"
}

show_adc()
{
	adc_raw="$(read_adc_raw)" || adc_raw=""
	adc_mv="$(read_adc_mv)" || {
		echo "ADC${ADC_CHANNEL} read failed" >&2
		exit 1
	}

	vbat_mv="$(read_battery_mv)" || {
		echo "battery voltage conversion failed" >&2
		exit 1
	}

	[ -n "$adc_raw" ] && echo "adc${ADC_CHANNEL}_raw=${adc_raw}"
	echo "adc${ADC_CHANNEL}=${adc_mv}mV"
	echo "battery=${vbat_mv}mV"
	echo "level=$(battery_level_from_mv "$vbat_mv")"
	echo "adc_ref=${ADC_REF_MV}mV adc_max_raw=${ADC_MAX_RAW}"
	echo "scale=${VBAT_SCALE_NUM}/${VBAT_SCALE_DEN}"
	if [ -n "$BAT_CAL_LOW_RAW" ] && [ -n "$BAT_CAL_FULL_RAW" ]; then
		echo "calibration=${BAT_CAL_LOW_MV}mV:${BAT_CAL_LOW_RAW},${BAT_CAL_FULL_MV}mV:${BAT_CAL_FULL_RAW}"
	fi
}

watch_adc()
{
	while true; do
		show_adc
		sleep "$POLL_INTERVAL"
	done
}

test_leds()
{
	wait_all_leds || exit 1

	set_run_leds_off
	set_battery_level off

	for led in "$RUN_LED" "$STATUS_LED" "$BAT_LOW_LED" "$BAT_MID_LED" "$BAT_FULL_LED"; do
		echo "testing $led"
		set_led "$led" 1
		sleep 2
		set_led "$led" 0
	done
}

force_battery_level()
{
	level="$1"

	case "$level" in
		low|mid|full|off)
			wait_all_leds || exit 1
			set_battery_level "$level"
			echo "battery level forced to $level"
			;;
		*)
			echo "Usage: $0 level [low|mid|full|off]" >&2
			exit 1
			;;
	esac
}

case "$1" in
	start|"")
		start_leds
		;;
	stop)
		wait_all_leds || exit 1
		cleanup
		;;
	status)
		show_all_status
		;;
	adc|voltage)
		show_adc
		;;
	watch)
		watch_adc
		;;
	test)
		test_leds
		;;
	level)
		force_battery_level "$2"
		;;
	*)
		echo "Usage: $0 [start|stop|status|adc|watch|test|level low|level mid|level full|level off]" >&2
		echo "Optional: ACTIVE_LOW=1 RUN_INTERVAL=1 POLL_INTERVAL=1 ADC_CHANNEL=2 ADC_REF_MV=1800 ADC_MAX_RAW=4095 LOW_MAX_MV=3700 FULL_MIN_MV=4200 VBAT_SCALE_NUM=7 VBAT_SCALE_DEN=3 BAT_CAL_LOW_RAW=xxxx BAT_CAL_FULL_RAW=yyyy $0 start" >&2
		exit 1
		;;
esac
