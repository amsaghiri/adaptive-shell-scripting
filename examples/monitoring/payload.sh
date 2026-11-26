# Adaptive monitoring: fail (and so raise an alert) when the 1-minute load
# average is above a threshold.
LOAD_THRESHOLD="1.0"

load="$(cut -d' ' -f1 /proc/loadavg)"
if awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN { exit !(l > t) }'; then
  echo "ALERT: load $load is above $LOAD_THRESHOLD" >&2
  exit 1
fi
echo "load $load is within $LOAD_THRESHOLD"
