#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# This script evaluates the AMT driver in IPv6 relay mode, i.e. with the
# gateway<->relay (outer) transport carried over IPv6. It mirrors amt.sh but
# the AMT control + data plane runs over an IPv6 outer header:
#
#   amtg: mode gateway local <v6> discovery <v6>
#   amtr: mode relay   local <v6>
#
# Both IPv4 and IPv6 inner multicast are forwarded over the single v6 outer
# tunnel, exercising the v6 Relay Advertisement, Membership Query and
# multicast-data send paths.
#
# Four network-namespaces: LISTENER, SOURCE, GATEWAY, RELAY (same roles as
# amt.sh). Only the GATEWAY<->RELAY segment differs: it is IPv6.
#
#       +------------------------+
#       |    LISTENER netns      |
#       |  +------------------+  |
#       |  |       l_gw       |  |
#       |  |  192.168.0.2/24  |  |
#       |  |  2001:db8::2/64  |  |
#       |  +------------------+  |
#       +------------------------+
#                    .
#       +-----------------------------------------------------+
#       |                      GATEWAY netns                  |
#       |+---------------------------------------------------+|
#       ||                      br0                          ||
#       || +------------------+       +------------------+   ||
#       || |       gw_l       |       |       amtg       |   ||
#       || |  192.168.0.1/24  |       +--------+---------+   ||
#       || |  2001:db8::1/64  |                |             ||
#       || +------------------+                |             ||
#       |+-------------------------------------|-------------+|
#       |                             +--------+---------+    |
#       |                             |     gw_relay     |    |
#       |                             |  2001:db8:a::1/64|    |
#       |                             +------------------+    |
#       +-----------------------------------------------------+
#                                              .  (IPv6 outer)
#       +-----------------------------------------------------+
#       |                       RELAY netns                   |
#       |                    +------------------+              |
#       |                    |    relay_br      |              |
#       |                    | 172.17.0.1/24    |              |
#       |                    | 2001:db8:3::1/64 |              |
#       |                    | 2001:db8:a::2/64 |              |
#       |                    +---+----------+---+              |
#       |                  relay_gw     relay_src              |
#       |                             +------------------+       |
#       |                             |       amtr       |       |
#       |                             +------------------+       |
#       +-----------------------------------------------------+
#                    .
#       +------------------------+
#       |  +------------------+  |
#       |  |     src_relay    |  |
#       |  |   172.17.0.2/24  |  |
#       |  | 2001:db8:3::2/64 |  |
#       |  +------------------+  |
#       |      SOURCE netns      |
#       +------------------------+
#==============================================================================

# shellcheck disable=SC1091
source lib.sh

LISTENER=$(mktemp -u listener-XXXXXXXX) || exit 4
GATEWAY=$(mktemp -u gateway-XXXXXXXX) || exit 4
RELAY=$(mktemp -u relay-XXXXXXXX) || exit 4
SOURCE=$(mktemp -u source-XXXXXXXX) || exit 4
readonly LISTENER GATEWAY RELAY SOURCE
if [ -n "${PIM_ROOT:-}" ]; then
	mkdir -p "$PIM_ROOT" || exit 4
	PIMDIR=$(mktemp -d "${PIM_ROOT%/}/amt-pim-XXXXXXXX") || exit 4
else
	PIMDIR=$(mktemp -d) || exit 4
fi
readonly PIMDIR
# FRR drops privileges after start-up, to a user fixed at build time (usually
# "frr"). Let that user reach its run directory and read empty.conf. The run
# directory itself is not created here: FRR creates the directory of its pid
# file before it drops privileges and hands it to that user, so pid files,
# vty sockets and the zserv socket all go there.
chmod 0755 "$PIMDIR" || exit 4
readonly PIM_RUNDIR="$PIMDIR/run"
readonly PIM_LOGDIR="$PIMDIR/log"
readonly ZEBRA_SOCK="$PIM_RUNDIR/zserv.api"
readonly PIM_PATHSPACE="amt-${RELAY}"
readonly FRR_BINDIR="${FRR_BINDIR:-}"
readonly FRR_LIBDIR="${FRR_LIBDIR:-}"
MGMTD_PID=
ZEBRA_PID=
PIMD_PID=
PIM6D_PID=
SSM_PID=
PROBE4_PID=
PROBE6_PID=
ASSERT4_PID=
ASSERT6_PID=
MGMTD=
ZEBRA=
PIMD=
PIM6D=
VTYSH=
DIAGNOSTICS_DUMPED=0
ERR=4
readonly LISTENER_READY="$PIMDIR/listener.ready"
readonly READY4="$PIMDIR/ipv4.ready"
readonly READY6="$PIMDIR/ipv6.ready"
readonly RESULT4="$PIMDIR/ipv4.result"
readonly RESULT6="$PIMDIR/ipv6.result"
readonly MFC4_STATUS="$PIMDIR/ipv4.mfc.status"
readonly MFC6_STATUS="$PIMDIR/ipv6.mfc.status"
readonly FORWARD4_STATUS="$PIMDIR/ipv4.forward.status"
readonly FORWARD6_STATUS="$PIMDIR/ipv6.forward.status"
readonly V4_SOURCE="172.17.0.2"
readonly V4_GROUP="232.0.0.1"
readonly V6_SOURCE="2001:db8:3::2"
readonly V6_GROUP="ff3e::5:6"
readonly V4_PAYLOAD="amt-v6-ipv4:${V4_SOURCE}"
readonly V6_PAYLOAD="amt-v6-ipv6:${V6_SOURCE}"

stop_daemon()
{
	local pid="$1"
	local attempt=0

	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		while [ "$attempt" -lt 20 ]; do
			attempt=$((attempt + 1))
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.05
		done
		kill -KILL "$pid" 2>/dev/null || true
	fi
	if [ -n "$pid" ]; then
		wait "$pid" 2>/dev/null || true
	fi
}

stop_frr()
{
	stop_daemon "$PIM6D_PID"
	stop_daemon "$PIMD_PID"
	stop_daemon "$ZEBRA_PID"
	stop_daemon "$MGMTD_PID"
}

stop_ssm_memberships()
{
	if [ -n "$SSM_PID" ]; then
		kill "$SSM_PID" 2>/dev/null || true
		wait "$SSM_PID" 2>/dev/null || true
		SSM_PID=
	fi
}

stop_probe_loops()
{
	stop_daemon "$PROBE4_PID"
	stop_daemon "$PROBE6_PID"
	PROBE4_PID=
	PROBE6_PID=
}

stop_assert_loops()
{
	stop_daemon "$ASSERT4_PID"
	stop_daemon "$ASSERT6_PID"
	ASSERT4_PID=
	ASSERT6_PID=
}

write_status()
{
	local path="$1" value="$2"

	printf '%s\n' "$value" >"$path.tmp"
	mv -f "$path.tmp" "$path"
}

dump_mcast_state()
{
	[ "$DIAGNOSTICS_DUMPED" -eq 0 ] || return 0
	DIAGNOSTICS_DUMPED=1

	echo "=== AMT PIM/IGMP/MLD diagnostics ===" >&2
	for ns in "$LISTENER" "$GATEWAY" "$RELAY" "$SOURCE"; do
		echo "--- namespace $ns ---" >&2
		ip netns exec "$ns" ip -d -s link show 2>&1 || true
		ip netns exec "$ns" ip -4 addr show 2>&1 || true
		ip netns exec "$ns" ip -6 addr show 2>&1 || true
		ip netns exec "$ns" ip route show 2>&1 || true
		ip netns exec "$ns" ip -6 route show 2>&1 || true
	done
	echo "--- relay multicast routes ---" >&2
	ip netns exec "$RELAY" ip mroute show 2>&1 || true
	ip netns exec "$RELAY" ip -6 mroute show 2>&1 || true
	echo "--- relay host membership tables ---" >&2
	ip netns exec "$RELAY" cat /proc/net/igmp 2>&1 || true
	ip netns exec "$RELAY" cat /proc/net/igmp6 2>&1 || true
	if [ -x "$VTYSH" ]; then
		echo "--- mgmtd state ---" >&2
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d mgmtd -c "show mgmt backend-adapter all" 2>&1 || true
		echo "--- pimd state ---" >&2
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pimd -c "show ip pim interface" 2>&1 || true
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pimd -c "show ip igmp groups" 2>&1 || true
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pimd -c "show ip mroute" 2>&1 || true
		echo "--- pim6d state ---" >&2
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pim6d -c "show ipv6 pim interface" 2>&1 || true
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pim6d -c "show ipv6 mld groups" 2>&1 || true
		ip netns exec "$RELAY" timeout 3 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d pim6d -c "show ipv6 mroute" 2>&1 || true
	fi
	for log in "$PIM_LOGDIR"/*.log; do
		[ -f "$log" ] || continue
		echo "--- $log ---" >&2
		tail -n 200 "$log" >&2 || true
	done
}

exit_cleanup()
{
	local status="$ERR"

	if [ "$status" -ne 0 ]; then
		dump_mcast_state
	fi
	stop_ssm_memberships
	stop_probe_loops
	stop_assert_loops
	stop_frr
	for ns in "$@"; do
		ip netns delete "${ns}" 2>/dev/null || true
	done
	if [ "${KEEP_PIMDIR:-0}" -ne 1 ]; then
		rm -rf "$PIMDIR"
	fi

	exit "$status"
}

create_namespaces()
{
	ip netns add "${LISTENER}" || exit_cleanup
	ip netns add "${GATEWAY}" || exit_cleanup "${LISTENER}"
	ip netns add "${RELAY}" || exit_cleanup "${LISTENER}" "${GATEWAY}"
	ip netns add "${SOURCE}" || exit_cleanup "${LISTENER}" "${GATEWAY}" \
		"${RELAY}"
}

# The trap function handler
#
exit_cleanup_all()
{
	exit_cleanup "${LISTENER}" "${GATEWAY}" "${RELAY}" "${SOURCE}"
}

setup_interface()
{
	for ns in "${LISTENER}" "${GATEWAY}" "${RELAY}" "${SOURCE}"; do
		ip -netns "${ns}" link set dev lo up
	done;

	ip link add l_gw type veth peer name gw_l
	ip link add gw_relay type veth peer name relay_gw
	ip link add relay_src type veth peer name src_relay

	ip link set l_gw netns "${LISTENER}" up
	ip link set gw_l netns "${GATEWAY}" up
	ip link set gw_relay netns "${GATEWAY}" up
	ip link set relay_gw netns "${RELAY}" up
	ip link set relay_src netns "${RELAY}" up
	ip link set src_relay netns "${SOURCE}" up mtu 1400
	ip netns exec "${RELAY}" ip link add relay_br type bridge
	ip netns exec "${RELAY}" ip link set relay_br up
	ip netns exec "${RELAY}" ip link set relay_gw master relay_br
	ip netns exec "${RELAY}" ip link set relay_src master relay_br
	ip netns exec "${RELAY}" ip link set relay_gw up
	ip netns exec "${RELAY}" ip link set relay_src up

	ip netns exec "${LISTENER}" ip a a 192.168.0.2/24 dev l_gw
	ip netns exec "${LISTENER}" ip r a default via 192.168.0.1 dev l_gw
	ip netns exec "${LISTENER}" ip a a 2001:db8::2/64 dev l_gw
	ip netns exec "${LISTENER}" ip r a default via 2001:db8::1 dev l_gw
	# The embedded listener installs source-specific INCLUDE memberships. FRR
	# learns the resulting (S,G) state through the AMT downstream interface.

	ip netns exec "${GATEWAY}" ip a a 192.168.0.1/24 dev gw_l
	ip netns exec "${GATEWAY}" ip a a 2001:db8::1/64 dev gw_l
	ip netns exec "${GATEWAY}" ip a a 2001:db8:a::1/64 dev gw_relay nodad
	ip netns exec "${GATEWAY}" ip link add br0 type bridge
	ip netns exec "${GATEWAY}" ip link set br0 up
	ip netns exec "${GATEWAY}" ip link set gw_l master br0
	ip netns exec "${GATEWAY}" ip link set gw_l up
	# IPv6 outer transport: gateway discovers the relay at its v6 address.
	ip netns exec "${GATEWAY}" ip link add amtg master br0 type amt \
		mode gateway local 2001:db8:a::1 discovery 2001:db8:a::2 \
		dev gw_relay gateway_port 2268 relay_port 2268
	ip netns exec "${RELAY}" ip a a 2001:db8:a::2/64 dev relay_br nodad
	# IPv6 outer transport: relay binds its v6 local address.
	ip netns exec "${RELAY}" ip link add amtr type amt mode relay \
		local 2001:db8:a::2 dev relay_br relay_port 2268 max_tunnels 4
	ip netns exec "${RELAY}" ip a a 172.17.0.1/24 dev relay_br
	ip netns exec "${RELAY}" ip a a 2001:db8:3::1/64 dev relay_br
	ip netns exec "${RELAY}" ip a a 192.168.0.1/24 dev amtr
	ip netns exec "${SOURCE}" ip a a "$V4_SOURCE/24" dev src_relay
	ip netns exec "${SOURCE}" ip a a "$V6_SOURCE/64" dev src_relay
	ip netns exec "${SOURCE}" ip r a default via 172.17.0.1 dev src_relay
	ip netns exec "${SOURCE}" ip r a default via 2001:db8:3::1 dev src_relay
	ip netns exec "${RELAY}" ip link set amtr up
	wait_relay_link_local
}

start_ssm_memberships()
{
	cat >"$PIMDIR/amt_ssm_listener.py" <<'PY'
#!/usr/bin/env python3
import os
import select
import signal
import socket
import struct
import sys


IP_ADD_SOURCE_MEMBERSHIP = getattr(socket, "IP_ADD_SOURCE_MEMBERSHIP", 39)
MCAST_JOIN_SOURCE_GROUP = getattr(socket, "MCAST_JOIN_SOURCE_GROUP", 46)


def sockaddr_storage(address):
	storage = bytearray(128)
	struct.pack_into("=H", storage, 0, socket.AF_INET6)
	storage[8:24] = socket.inet_pton(socket.AF_INET6, address)
	return bytes(storage)


def write_file(path, contents):
	temporary = path + ".tmp"
	with open(temporary, "w", encoding="ascii") as stream:
		stream.write(contents)
		stream.flush()
		os.fsync(stream.fileno())
	os.replace(temporary, path)


def join_ipv4(ifaddr, source, group, port, ready):
	sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
	sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	sock.bind(("0.0.0.0", port))
	sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
	               socket.inet_aton(ifaddr))
	request = struct.pack("=4s4s4s", socket.inet_aton(group),
	                      socket.inet_aton(ifaddr), socket.inet_aton(source))
	sock.setsockopt(socket.IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, request)
	write_file(ready, "ready\n")
	return sock


def join_ipv6(ifname, source, group, port, ready):
	sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
	sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
	sock.bind(("::", port))
	ifindex = socket.if_nametoindex(ifname)
	sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, ifindex)
	# Linux group_source_req is ifindex, four bytes of padding, and two
	# sockaddr_storage values. Keep the layout explicit for 64-bit guests.
	request = (struct.pack("=I", ifindex) + b"\0" * 4 +
	           sockaddr_storage(group) + sockaddr_storage(source))
	sock.setsockopt(socket.IPPROTO_IPV6, MCAST_JOIN_SOURCE_GROUP, request)
	write_file(ready, "ready\n")
	return sock


def record_packet(path, family, peer, payload):
	write_file(path, "family=%s\nsender=%s\npayload=%s\n" %
	           (family, peer, payload.decode("ascii")))


def main():
	if len(sys.argv) != 14:
		raise SystemExit("usage: listener IFACE V4_ADDR V4_SOURCE V4_GROUP "
	                 "V6_SOURCE V6_GROUP READY READY4 READY6 RESULT4 "
	                 "RESULT6 PAYLOAD4 PAYLOAD6")
	(ifname, v4_addr, v4_source, v4_group, v6_source, v6_group,
	 ready, ready4, ready6, result4, result6, payload4, payload6) = sys.argv[1:]
	sockets = []
	try:
		sock4 = join_ipv4(v4_addr, v4_source, v4_group, 4000, ready4)
		sockets.append((sock4, v4_source, payload4.encode("ascii"),
					result4, "ipv4"))
		sock6 = join_ipv6(ifname, v6_source, v6_group, 6000, ready6)
		sockets.append((sock6, v6_source, payload6.encode("ascii"),
					result6, "ipv6"))
		write_file(ready, "ready\n")
	except Exception as error:
		print("listener setup failed: %s" % error, file=sys.stderr, flush=True)
		return 1

	stopping = False

	def stop(_signum, _frame):
		nonlocal stopping
		stopping = True

	signal.signal(signal.SIGTERM, stop)
	signal.signal(signal.SIGINT, stop)
	while not stopping:
		readable, _, _ = select.select([item[0] for item in sockets], [], [], 1.0)
		for sock, expected_source, expected_payload, result, family in sockets:
			if sock not in readable:
				continue
			data, peer = sock.recvfrom(4096)
			if peer[0] != expected_source or data != expected_payload:
				print("ignored %s packet from %s" % (family, peer[0]),
				      file=sys.stderr, flush=True)
				continue
			record_packet(result, family, peer[0], data)
	for sock, _, _, _, _ in sockets:
		sock.close()
	return 0


if __name__ == "__main__":
	sys.exit(main())
PY
	chmod 755 "$PIMDIR/amt_ssm_listener.py"
	ip netns exec "${LISTENER}" python3 "$PIMDIR/amt_ssm_listener.py" \
		l_gw 192.168.0.2 "$V4_SOURCE" "$V4_GROUP" "$V6_SOURCE" \
		"$V6_GROUP" "$LISTENER_READY" "$READY4" "$READY6" "$RESULT4" \
		"$RESULT6" "$V4_PAYLOAD" "$V6_PAYLOAD" \
		>"$PIMDIR/ssm-listener.log" 2>&1 &
	SSM_PID=$!
	local attempt=0
	while [ "$attempt" -lt 200 ]; do
		attempt=$((attempt + 1))
		if ! kill -0 "$SSM_PID" 2>/dev/null; then
			cat "$PIMDIR/ssm-listener.log" >&2 || true
			return 1
		fi
		if [ -f "$LISTENER_READY" ] && [ -f "$READY4" ] &&
			[ -f "$READY6" ]; then
			return 0
		fi
		sleep 0.05
	done
	cat "$PIMDIR/ssm-listener.log" >&2 || true
	return 1
}

setup_sysctl()
{
	ip netns exec "${RELAY}" sysctl net.ipv4.ip_forward=1 -w -q
	ip netns exec "${RELAY}" sysctl net.ipv6.conf.all.forwarding=1 -w -q
	ip netns exec "${SOURCE}" sysctl net.ipv4.ip_default_ttl=2 -w -q
	ip netns exec "${SOURCE}" sysctl net.ipv6.conf.all.hop_limit=2 -w -q
}

setup_iptables()
{
	ip netns exec "${RELAY}" iptables -t mangle -I PREROUTING \
		-p udp -d "$V4_GROUP" -j TTL --ttl-set 2
	ip netns exec "${RELAY}" ip6tables -t mangle -I PREROUTING \
		-p udp -d "$V6_GROUP" -j HL --hl-set 2
}

wait_relay_link_local()
{
	local attempt=0

	while [ "$attempt" -lt 100 ]; do
		attempt=$((attempt + 1))
		if ip netns exec "${RELAY}" ip -6 -o addr show dev amtr scope link |
			awk '$4 ~ /^fe80::/ && $0 !~ /tentative|dadfailed/ { ok = 1 }
			     END { exit !ok }'; then
			return 0
		fi
		sleep 0.05
	done

	echo "amtr has no usable IPv6 link-local address" >&2
	ip netns exec "${RELAY}" ip -6 addr show dev amtr >&2
	return 1
}

frr_binary()
{
	local name="$1"

	if [ -n "$FRR_BINDIR" ] && [ -x "$FRR_BINDIR/$name" ]; then
		printf '%s\n' "$FRR_BINDIR/$name"
	elif [ "$name" = "vtysh" ] && [ -n "$FRR_BINDIR" ] &&
		[ -x "${FRR_BINDIR%/}/../bin/vtysh" ]; then
		printf '%s\n' "${FRR_BINDIR%/}/../bin/vtysh"
	elif command -v "$name" >/dev/null 2>&1; then
		command -v "$name"
	elif [ -x "/usr/lib/frr/$name" ]; then
		printf '%s\n' "/usr/lib/frr/$name"
	else
		return 1
	fi
}

wait_for_frr()
{
	local name="$1" pid="$2" socket="$3"
	local attempt=0

	while [ "$attempt" -lt 100 ]; do
		attempt=$((attempt + 1))
		if ! kill -0 "$pid" 2>/dev/null; then
			echo "$name exited before becoming ready" >&2
			return 1
		fi
		if [ -z "$socket" ] || [ -S "$socket" ]; then
			return 0
		fi
		sleep 0.05
	done
	echo "$name did not become ready" >&2
	return 1
}

wait_for_zebra_sync()
{
	local attempt=0

	# Zebra's initial netlink dump is asynchronous.  Do not start PIM until
	# it can report the addresses that were installed before zebra started.
	while [ "$attempt" -lt 100 ]; do
		attempt=$((attempt + 1))
		if ip netns exec "$RELAY" ip -4 -o addr show dev relay_br |
			grep -q '172\.17\.0\.1/24' &&
			ip netns exec "$RELAY" ip -4 -o addr show dev amtr |
				grep -q '192\.168\.0\.1/24' &&
			ip netns exec "$RELAY" ip -6 -o addr show dev relay_br |
			grep -q '2001:db8:3::1/64'; then
			return 0
		fi
		sleep 0.05
	done
	echo "zebra did not synchronize relay addresses" >&2
	return 1
}

wait_for_vty_command()
{
	local daemon="$1" command="$2"
	local attempt=0

	while [ "$attempt" -lt 200 ]; do
		attempt=$((attempt + 1))
		if ip netns exec "$RELAY" timeout 2 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d "$daemon" -c "$command" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.05
	done
	echo "$daemon did not answer '$command'" >&2
	return 1
}

wait_for_mgmtd_backend()
{
	local name="$1"
	local attempt=0

	while [ "$attempt" -lt 100 ]; do
		attempt=$((attempt + 1))
		if ip netns exec "$RELAY" timeout 2 "$VTYSH" \
			--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
			-d mgmtd -c "show mgmt backend-adapter all" 2>/dev/null |
			grep -qw "$name"; then
			return 0
		fi
		sleep 0.05
	done
	echo "$name did not connect to mgmtd" >&2
	return 1
}

mroute_has_oif()
{
	local family="$1" source="$2" group="$3"
	local output

	if [ "$family" -eq 4 ]; then
		output=$(ip netns exec "$RELAY" timeout 1 ip mroute show 2>/dev/null || true)
	else
		output=$(ip netns exec "$RELAY" timeout 1 ip -6 mroute show 2>/dev/null || true)
	fi

	# iproute2 prints one route record beginning with an exact (S,G) key. It
	# may include whitespace after the comma, so normalize only that key before
	# comparing it; an OIF on an adjacent route must never satisfy this assertion.
	printf '%s\n' "$output" | awk -v source="$source" -v group="$group" '
	function route_token(line, token) {
		sub(/^[[:space:]]*/, "", line)
		token = line
		sub(/[[:space:]]+Iif:.*/, "", token); gsub(/[[:space:]]/, "", token)
		return token
	}
	/^[[:space:]]*\(/ {
		in_record = (route_token($0) == "(" source "," group ")")
	}
	/Oifs:/ {
		if (!in_record)
			next
		oifs = $0
		sub(/^.*Oifs:[[:space:]]*/, "", oifs)
		sub(/[[:space:]]+State:.*$/, "", oifs)
		count = split(oifs, names, /[[:space:]]+/)
		for (i = 1; i <= count; i++) {
			sub(/\(.*/, "", names[i])
			if (names[i] == "amtr")
				matched = 1
		}
	}
	END { exit !matched }'
}

wait_for_mroutes()
{
	local mfc4_done=0 mfc6_done=0
	local attempt=0

	rm -f "$MFC4_STATUS" "$MFC6_STATUS"
	while [ "$attempt" -lt 200 ]; do
		attempt=$((attempt + 1))
		if [ "$mfc4_done" -eq 0 ] &&
			mroute_has_oif 4 "$V4_SOURCE" "$V4_GROUP"; then
			write_status "$MFC4_STATUS" pass
			mfc4_done=1
			printf 'PIM: %-8s IPv4  %s -> %s via amtr [ OK ]\n' \
				"source-specific" "$V4_SOURCE" "$V4_GROUP"
		fi
		if [ "$mfc6_done" -eq 0 ] &&
			mroute_has_oif 6 "$V6_SOURCE" "$V6_GROUP"; then
			write_status "$MFC6_STATUS" pass
			mfc6_done=1
			printf 'PIM: %-8s IPv6  %s -> %s via amtr [ OK ]\n' \
				"source-specific" "$V6_SOURCE" "$V6_GROUP"
		fi
		[ "$mfc4_done" -eq 1 ] && [ "$mfc6_done" -eq 1 ] && return 0
		sleep 0.1
	done

	if [ "$mfc4_done" -eq 0 ]; then
		write_status "$MFC4_STATUS" fail
		echo "PIM: timed out waiting for IPv4 route $V4_SOURCE -> $V4_GROUP via amtr" >&2
	fi
	if [ "$mfc6_done" -eq 0 ]; then
		write_status "$MFC6_STATUS" fail
		echo "PIM: timed out waiting for IPv6 route $V6_SOURCE -> $V6_GROUP via amtr" >&2
	fi
	dump_mcast_state
	return 0
}

send_mcast_probe4()
{
	printf 'probe4' | ip netns exec "${SOURCE}" nc -4 -u -s "$V4_SOURCE" \
		-w 1 -M 2 "$V4_GROUP" 4001 >/dev/null 2>&1 || true
}

send_mcast_probe6()
{
	printf 'probe6' | ip netns exec "${SOURCE}" nc -6 -u -s "$V6_SOURCE" \
		-w 1 -M 2 "$V6_GROUP" 6001 >/dev/null 2>&1 || true
}

probe_loop4()
{
	while [ ! -f "$MFC4_STATUS" ]; do
		send_mcast_probe4
		sleep 0.1
	done
}

probe_loop6()
{
	while [ ! -f "$MFC6_STATUS" ]; do
		send_mcast_probe6
		sleep 0.1
	done
}

setup_mcast_routing()
{
	mkdir -p "$PIM_LOGDIR"
	touch "$PIMDIR/vtysh.conf"

	# Let mgmtd apply one unified routing configuration after every backend is
	# ready. Addresses are installed before the daemons start so both PIM
	# processes see usable primary addresses during interface initialization.
	touch "$PIMDIR/empty.conf"
	chmod 0644 "$PIMDIR/empty.conf"
	# Both groups are inside FRR's default SSM ranges (232.0.0.0/8 and
	# ff3x::/32), so no "ssm prefix-list" is configured. Not every FRR
	# release accepts one under "router pim6"; FRR 10.3 does not.
	cat >"$PIMDIR/frr.conf" <<-EOF
	hostname amt-relay
	interface relay_br
	 ip pim ssm
	 ip igmp
	 ip igmp version 3
	 ipv6 pim ssm
	 ipv6 mld
	 ipv6 mld version 2
	interface amtr
	 ip pim ssm
	 ip igmp
	 ip igmp version 3
	 ipv6 pim ssm
	 ipv6 mld
	 ipv6 mld version 2
	EOF

	ip netns exec "$RELAY" "$MGMTD" -N "$PIM_PATHSPACE" \
		--vty_socket "$PIM_RUNDIR" \
		${FRR_LIBDIR:+--moduledir "$FRR_LIBDIR/frr/modules"} \
		--log "file:$PIM_LOGDIR/mgmtd.log" \
		--pid_file "$PIM_RUNDIR/mgmtd.pid" >"$PIM_LOGDIR/mgmtd.startup" 2>&1 &
	MGMTD_PID=$!
	wait_for_frr mgmtd "$MGMTD_PID" "$PIM_RUNDIR/mgmtd.vty"
	wait_for_vty_command mgmtd "show mgmt backend-adapter all"

	ip netns exec "$RELAY" "$ZEBRA" \
		-N "$PIM_PATHSPACE" --config_file "$PIMDIR/empty.conf" \
		--socket "$ZEBRA_SOCK" --vty_socket "$PIM_RUNDIR" \
		${FRR_LIBDIR:+--moduledir "$FRR_LIBDIR/frr/modules"} \
		--log "file:$PIM_LOGDIR/zebra.log" \
		--pid_file "$PIM_RUNDIR/zebra.pid" >"$PIM_LOGDIR/zebra.startup" 2>&1 &
	ZEBRA_PID=$!
	wait_for_frr zebra "$ZEBRA_PID" "$ZEBRA_SOCK"
	wait_for_mgmtd_backend zebra

	ip netns exec "$RELAY" "$PIMD" \
		-N "$PIM_PATHSPACE" --config_file "$PIMDIR/empty.conf" \
		--socket "$ZEBRA_SOCK" --vty_socket "$PIM_RUNDIR" \
		${FRR_LIBDIR:+--moduledir "$FRR_LIBDIR/frr/modules"} \
		--log "file:$PIM_LOGDIR/pimd.log" \
		--pid_file "$PIM_RUNDIR/pimd.pid" >"$PIM_LOGDIR/pimd.startup" 2>&1 &
	PIMD_PID=$!
	wait_for_frr pimd "$PIMD_PID" "$PIM_RUNDIR/pimd.vty"
	wait_for_vty_command pimd "show ip pim interface"

	ip netns exec "$RELAY" "$PIM6D" \
		-N "$PIM_PATHSPACE" --config_file "$PIMDIR/empty.conf" \
		--socket "$ZEBRA_SOCK" --vty_socket "$PIM_RUNDIR" \
		${FRR_LIBDIR:+--moduledir "$FRR_LIBDIR/frr/modules"} \
		--log "file:$PIM_LOGDIR/pim6d.log" \
		--pid_file "$PIM_RUNDIR/pim6d.pid" >"$PIM_LOGDIR/pim6d.startup" 2>&1 &
	PIM6D_PID=$!
	wait_for_frr pim6d "$PIM6D_PID" "$PIM_RUNDIR/pim6d.vty"
	wait_for_vty_command pim6d "show ipv6 pim interface"

	ip netns exec "$RELAY" timeout 15 "$VTYSH" \
		--config_dir "$PIMDIR" --vty_socket "$PIM_RUNDIR" \
		-f "$PIMDIR/frr.conf" >"$PIM_LOGDIR/vtysh.log" 2>&1
	wait_for_zebra_sync
}

test_remote_ip()
{
	local remote deadline=$((SECONDS + 10))

	while [ "$SECONDS" -lt "$deadline" ]; do
		remote=$(ip netns exec "${GATEWAY}" ip -d -j link show amtg \
			2>/dev/null | jq -r '.[0].linkinfo.info_data.remote // empty') ||
			remote=
		if [ "$remote" = "2001:db8:a::2" ]; then
			printf "TEST: %-60s  [ OK ]\n" "amt discovery (IPv6 outer)"
			return 0
		fi
		sleep 0.05
	done
	printf "TEST: %-60s  [FAIL]\n" "amt discovery (IPv6 outer)"
	echo "      expected remote 2001:db8:a::2, got '${remote}'" >&2
	ERR=1
}

check_features()
{
	if ! ip link help 2>&1 | grep -q amt; then
		echo "Missing amt support in iproute2" >&2
		exit_cleanup
	fi

	ZEBRA=$(frr_binary zebra) || {
		echo "Missing FRR zebra" >&2
		exit_cleanup
	}
	MGMTD=$(frr_binary mgmtd) || {
		echo "Missing FRR mgmtd" >&2
		exit_cleanup
	}
	PIMD=$(frr_binary pimd) || {
		echo "Missing FRR pimd" >&2
		exit_cleanup
	}
	PIM6D=$(frr_binary pim6d) || {
		echo "Missing FRR pim6d" >&2
		exit_cleanup
	}
	VTYSH=$(frr_binary vtysh) || {
		echo "Missing FRR vtysh" >&2
		exit_cleanup
	}
}

result_has_packet()
{
	local result="$1" family="$2" source="$3" payload="$4"
	[ -f "$result" ] || return 1
	grep -Fxq "family=$family" "$result" &&
	grep -Fxq "sender=$source" "$result" &&
	grep -Fxq "payload=$payload" "$result"
}

send_payload_loop4()
{
	while [ ! -f "$FORWARD4_STATUS" ]; do
		printf '%s' "$V4_PAYLOAD" | ip netns exec "${SOURCE}" \
			nc -4 -u -s "$V4_SOURCE" -w 1 -M 2 "$V4_GROUP" 4000 \
			>/dev/null 2>&1 || true
		sleep 0.1
	done
}

send_payload_loop6()
{
	while [ ! -f "$FORWARD6_STATUS" ]; do
		printf '%s' "$V6_PAYLOAD" | ip netns exec "${SOURCE}" \
			nc -6 -u -s "$V6_SOURCE" -w 1 -M 2 "$V6_GROUP" 6000 \
			>/dev/null 2>&1 || true
		sleep 0.1
	done
}

wait_for_forward_results()
{
	local forward4_done=0 forward6_done=0
	local deadline=$((SECONDS + 25))

	while [ "$SECONDS" -lt "$deadline" ]; do
		if [ "$forward4_done" -eq 0 ] && result_has_packet \
			"$RESULT4" ipv4 "$V4_SOURCE" "$V4_PAYLOAD"; then
			write_status "$FORWARD4_STATUS" pass
			forward4_done=1
			printf "TEST: %-60s  [ OK ]\n" \
				"IPv4-in-IPv6 amt multicast forwarding"
		fi
		if [ "$forward6_done" -eq 0 ] && result_has_packet \
			"$RESULT6" ipv6 "$V6_SOURCE" "$V6_PAYLOAD"; then
			write_status "$FORWARD6_STATUS" pass
			forward6_done=1
			printf "TEST: %-60s  [ OK ]\n" \
				"IPv6-in-IPv6 amt multicast forwarding"
		fi
		[ "$forward4_done" -eq 1 ] && [ "$forward6_done" -eq 1 ] && break
		sleep 0.1
	done
	if [ "$forward4_done" -eq 0 ]; then
		write_status "$FORWARD4_STATUS" fail
		printf "TEST: %-60s  [FAIL]\n" \
			"IPv4-in-IPv6 amt multicast forwarding"
	fi
	if [ "$forward6_done" -eq 0 ]; then
		write_status "$FORWARD6_STATUS" fail
		printf "TEST: %-60s  [FAIL]\n" \
			"IPv6-in-IPv6 amt multicast forwarding"
	fi
}

check_features

create_namespaces

set -e
trap exit_cleanup_all EXIT

setup_interface
start_ssm_memberships
setup_sysctl
setup_iptables
setup_mcast_routing
ip netns exec "${GATEWAY}" ip link set amtg up
ERR=0
test_remote_ip
probe_loop4 &
PROBE4_PID=$!

probe_loop6 &
PROBE6_PID=$!
wait_for_mroutes
stop_probe_loops

rm -f "$FORWARD4_STATUS" "$FORWARD6_STATUS"
send_payload_loop4 &
ASSERT4_PID=$!
send_payload_loop6 &
ASSERT6_PID=$!
wait_for_forward_results
stop_assert_loops

if [ "$ERR" -ne 0 ] ||
	[ "$(cat "$MFC4_STATUS")" != "pass" ] ||
	[ "$(cat "$MFC6_STATUS")" != "pass" ] ||
	[ "$(cat "$FORWARD4_STATUS")" != "pass" ] ||
	[ "$(cat "$FORWARD6_STATUS")" != "pass" ]; then
	ERR=1
else
	ERR=0
fi
