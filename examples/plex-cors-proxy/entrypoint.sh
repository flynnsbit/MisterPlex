#!/bin/sh
set -eu

PMS_LAN_IP=${PMS_LAN_IP:?PMS_LAN_IP is required}
PROXY_PORT=${PROXY_PORT:-32402}
RULE_COMMENT=misterplex-plex-cors

add_rule() {
    chain=$1
    shift
    if ! iptables -t nat -C "$chain" "$@" 2>/dev/null; then
        iptables -t nat -I "$chain" 1 "$@"
    fi
}

delete_rule() {
    chain=$1
    shift
    while iptables -t nat -C "$chain" "$@" 2>/dev/null; do
        iptables -t nat -D "$chain" "$@"
    done
}

loopback_rule="OUTPUT -p tcp -d 127.0.0.1 --dport 32400 -m comment --comment $RULE_COMMENT -j REDIRECT --to-ports $PROXY_PORT"
lan_output_rule="OUTPUT -p tcp -d $PMS_LAN_IP --dport 32400 -m comment --comment $RULE_COMMENT -j REDIRECT --to-ports $PROXY_PORT"
lan_input_rule="PREROUTING -p tcp -d $PMS_LAN_IP --dport 32400 -m comment --comment $RULE_COMMENT -j REDIRECT --to-ports $PROXY_PORT"

cleanup() {
    delete_rule $loopback_rule
    delete_rule $lan_output_rule
    delete_rule $lan_input_rule
    if [ -n "${nginx_pid:-}" ]; then
        kill "$nginx_pid" 2>/dev/null || true
        wait "$nginx_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

nginx -t
nginx -g "daemon off;" &
nginx_pid=$!

for _ in $(seq 1 50); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PROXY_PORT/identity" >/dev/null; then
        break
    fi
    sleep 0.1
done
curl -fsS --max-time 2 "http://127.0.0.1:$PROXY_PORT/identity" >/dev/null

add_rule $loopback_rule
add_rule $lan_output_rule
add_rule $lan_input_rule

wait "$nginx_pid"
