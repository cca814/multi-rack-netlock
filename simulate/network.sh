#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "Run through make sim-up / make p4-up / make sim-down (requires root)." >&2
    exit 1
fi

exists() {
    ip netns list | awk '{print $1}' | grep -Fxq "$1"
}

case "${1:-}" in
    up|up-p4)
        if exists netlock-client || exists netlock-server; then
            echo "Simulation namespaces already exist; use make sim-down before recreating them." >&2
            exit 1
        fi
        if [[ "$1" == up-p4 ]]; then
            for interface in sw-client sw-server; do
                if ip link show dev "$interface" >/dev/null 2>&1; then
                    echo "Interface $interface already exists; refusing to overwrite it." >&2
                    exit 1
                fi
            done
        fi
        client_created=0
        server_created=0
        rollback() {
            if (( client_created )); then ip netns delete netlock-client; fi
            if (( server_created )); then ip netns delete netlock-server; fi
        }
        trap rollback EXIT
        ip netns add netlock-client
        client_created=1
        ip netns add netlock-server
        server_created=1
        if [[ "$1" == up-p4 ]]; then
            # Create peers in their namespaces so rollback also removes host links.
            ip link add sw-client type veth peer name nl-client netns netlock-client
            ip link add sw-server type veth peer name nl-server netns netlock-server
            ip link set sw-client up promisc on
            ip link set sw-server up promisc on
        else
            ip -n netlock-client link add nl-client type veth peer name nl-server
            ip -n netlock-client link set nl-server netns netlock-server
        fi
        ip -n netlock-client link set lo up
        ip -n netlock-server link set lo up
        ip -n netlock-client link set nl-client address 02:00:00:00:00:01
        ip -n netlock-server link set nl-server address 02:00:00:00:00:02
        ip -n netlock-client address add 10.200.0.1/24 dev nl-client
        ip -n netlock-server address add 10.200.0.2/24 dev nl-server
        ip -n netlock-client link set nl-client up
        ip -n netlock-server link set nl-server up
        trap - EXIT
        if [[ "$1" == up-p4 ]]; then
            echo "Ready: netlock-client (nl-client) <-> sw-client [P4 port 2 | port 1] sw-server <-> netlock-server (nl-server)"
        else
            echo "Ready: netlock-client (nl-client, 10.200.0.1) <-> netlock-server (nl-server, 10.200.0.2)"
        fi
        ;;
    down)
        for namespace in netlock-client netlock-server; do
            if exists "$namespace"; then
                if [[ -n "$(ip netns pids "$namespace")" ]]; then
                    echo "Exit processes in $namespace before removing the network." >&2
                    exit 1
                fi
            fi
        done
        for namespace in netlock-client netlock-server; do
            if exists "$namespace"; then ip netns delete "$namespace"; fi
        done
        ;;
    *)
        echo "Usage: $0 {up|up-p4|down}" >&2
        exit 2
        ;;
esac
