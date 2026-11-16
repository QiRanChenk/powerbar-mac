#!/bin/bash
# pbd: root service for powerbar (Apple Silicon). Polls /Users/Shared/powerbar every second.
#   mode: auto | on | off  -> Low Power Mode on battery / on AC via pmset; applied only when the file changes,
#         so a toggle in Control Center or System Settings still sticks until the next menu choice
#   lid:  awake | sleep    -> pmset -a disablesleep 1 | 0 (kept in sync)
#   status (written here): "<mode> <battery lpm> <ac lpm>"
D=/Users/Shared/powerbar
last=""
while true; do
  mode=$(head -c 16 "$D/mode" 2>/dev/null | tr -cd 'a-z')
  if [ -n "$mode" ] && [ "$mode" != "$last" ]; then
    case "$mode" in
      auto) /usr/bin/pmset -b lowpowermode 1; /usr/bin/pmset -c lowpowermode 0 ;;
      on)   /usr/bin/pmset -a lowpowermode 1 ;;
      off)  /usr/bin/pmset -a lowpowermode 0 ;;
    esac
    last=$mode
  fi
  lid=$(head -c 16 "$D/lid" 2>/dev/null | tr -cd 'a-z')
  cur=$(/usr/bin/pmset -g | awk '/SleepDisabled/{print $2}')
  case "$lid" in
    awake) [ "$cur" = 1 ] || /usr/bin/pmset -a disablesleep 1 ;;
    sleep) [ "$cur" = 0 ] || /usr/bin/pmset -a disablesleep 0 ;;
  esac
  read -r b c < <(/usr/bin/pmset -g custom | awk '/^Battery Power/{s="b"} /^AC Power/{s="c"} /lowpowermode/{v[s]=$2} END{print (v["b"]==""?"-":v["b"]), (v["c"]==""?"-":v["c"])}')
  if [ -d "$D" ]; then
    echo "${last:-none} $b $c" > "$D/status.tmp" && chmod 644 "$D/status.tmp" && mv -f "$D/status.tmp" "$D/status"
  fi
  sleep 1
done
