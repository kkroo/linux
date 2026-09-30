#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Netlink coverage for AMT IPv6 gateway mode: IFLA_AMT_DISCOVERY_IP6 and the
# rules that validate it. amt_v6.sh covers the data plane; this needs only one
# netns and one dummy device.
#
# Not covered: `discovery <v4>` together with `discovery <v6>`, or `local <v4>`
# together with `local <v6>`, in one command. iproute2 rejects the duplicate
# argument itself, so those checks are reachable only from a raw netlink
# client.

source lib.sh

readonly V6_LOCAL="2001:db8:a::1"
readonly V6_DISC="2001:db8:a::2"
readonly V4_LOCAL="192.168.0.1"
readonly V4_DISC="192.168.0.2"

# add_amt <name> <args...>: create an amt link on gw_dev, stderr in $ADD_ERR.
add_amt()
{
	local name=$1; shift

	ADD_ERR=$(ip -n "$GW" link add "$name" type amt dev gw_dev "$@" 2>&1)
}

# amt_field <name> <key>: one attribute as amt_fill_info reports it.
amt_field()
{
	ip -n "$GW" -d -j link show "$1" 2>/dev/null |
		jq -r ".[0].linkinfo.info_data.$2 // empty"
}

# An iproute2 without IFLA_AMT_DISCOVERY_IP6 does not reject `discovery <v6>`:
# it packs the first four bytes of the literal into IFLA_AMT_DISCOVERY_IP and
# the kernel creates a v4 gateway from them. So probe on the readback, not on
# the exit code.
probe_v6_gateway()
{
	local got

	if ! add_amt amtprobe mode gateway local "$V6_LOCAL" \
	     discovery "$V6_DISC"; then
		echo "SKIP: v6 gateway mode unavailable: $ADD_ERR"
		exit "$ksft_skip"
	fi
	got=$(amt_field amtprobe discovery)
	ip -n "$GW" link del amtprobe
	if [[ "$got" != *:* ]]; then
		echo "SKIP: iproute2 lacks IFLA_AMT_DISCOVERY_IP6 (read back '$got')"
		exit "$ksft_skip"
	fi
}

test_v6_gateway_roundtrip()
{
	RET=0
	add_amt amtg6 mode gateway local "$V6_LOCAL" discovery "$V6_DISC"
	check_err $? "create failed: $ADD_ERR"
	[ "$(amt_field amtg6 discovery)" = "$V6_DISC" ]
	check_err $? "discovery did not read back as $V6_DISC"
	[ "$(amt_field amtg6 local)" = "$V6_LOCAL" ]
	check_err $? "local did not read back as $V6_LOCAL"
	ip -n "$GW" link del amtg6 2>/dev/null
	log_test "v6 gateway: discovery round-trips through fill_info"
}

test_v4_gateway_unchanged()
{
	RET=0
	add_amt amtg4 mode gateway local "$V4_LOCAL" discovery "$V4_DISC"
	check_err $? "create failed: $ADD_ERR"
	[ "$(amt_field amtg4 discovery)" = "$V4_DISC" ]
	check_err $? "discovery did not read back as $V4_DISC"
	ip -n "$GW" link del amtg4 2>/dev/null
	log_test "v4 gateway still creates (no ABI change)"
}

# expect_reject <description> <extack substring> <args...>: the create must
# fail, and for the stated reason.
expect_reject()
{
	local desc=$1 want=$2; shift 2

	RET=0
	add_amt amtbad "$@"
	check_fail $? "link was created but should have been rejected"
	ip -n "$GW" link del amtbad 2>/dev/null
	grep -qi -- "$want" <<< "$ADD_ERR"
	check_err $? "rejected for the wrong reason: $ADD_ERR"
	log_test "$desc"
}

require_command jq
trap cleanup_all_ns EXIT
setup_ns GW || exit "$ksft_skip"
ip -n "$GW" link add gw_dev type dummy
ip -n "$GW" link set gw_dev up
ip -n "$GW" addr add "$V4_LOCAL/24" dev gw_dev
# nodad: a tentative source address would race link creation.
ip -n "$GW" addr add "$V6_LOCAL/64" dev gw_dev nodad

probe_v6_gateway

test_v6_gateway_roundtrip
test_v4_gateway_unchanged
expect_reject "gateway without discovery is rejected" \
	"Discovery attribute is required" \
	mode gateway local "$V6_LOCAL"
expect_reject "gateway v6 local + v4 discovery is rejected" \
	"same family" \
	mode gateway local "$V6_LOCAL" discovery "$V4_DISC"
expect_reject "gateway v4 local + v6 discovery is rejected" \
	"same family" \
	mode gateway local "$V4_LOCAL" discovery "$V6_DISC"
expect_reject "v6 discovery in relay mode is rejected" \
	"only valid in gateway mode" \
	mode relay local "$V6_LOCAL" discovery "$V6_DISC"

exit "$EXIT_STATUS"
