#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Netlink coverage for the AMT scaling attributes IFLA_AMT_HASH_BUCKETS,
# IFLA_AMT_MAX_GROUPS and IFLA_AMT_NUM_QUEUES: their defaults, the round trip
# of explicit values, a hash_buckets count that is not a power of two, and the
# upper bound of each attribute.

source lib.sh

# amt_add <args...>: create relay amt0 on the dummy device.
amt_add()
{
	ip -n "$NS" link add amt0 type amt dev eth-host \
		mode relay local 192.0.2.1 "$@"
}

# `ip link help amt` is answered by iproute2 alone, so probe the kernel with
# one create: without amt support every test would fail instead of skip.
probe_amt()
{
	local err

	if ! err=$(amt_add 2>&1); then
		echo "SKIP: amt relay unavailable: $err"
		exit "$ksft_skip"
	fi
	ip -n "$NS" link del amt0
}

# amt_check <attribute> <value>: compare one attribute that amt_fill_info
# reports for amt0.
amt_check()
{
	local got

	got=$(ip -n "$NS" -d -j link show amt0 2>/dev/null |
	      jq -r ".[0].linkinfo.info_data.$1")
	[ "$got" = "$2" ]
	check_err $? "$1: want $2, got $got"
}

test_defaults()
{
	RET=0
	amt_add
	check_err $? "create failed"
	amt_check max_tunnels 128
	amt_check hash_buckets 256
	amt_check max_groups 32
	amt_check num_queues 1
	ip -n "$NS" link del amt0 2>/dev/null
	log_test "defaults without scaling attributes"
}

test_override()
{
	RET=0
	amt_add max_tunnels 16384 max_groups 64 hash_buckets 4096 num_queues 8
	check_err $? "create failed"
	amt_check max_tunnels 16384
	amt_check max_groups 64
	amt_check hash_buckets 4096
	amt_check num_queues 8
	ip -n "$NS" link del amt0 2>/dev/null
	log_test "explicit values round-trip"
}

test_hash_buckets_not_pow2()
{
	RET=0
	amt_add hash_buckets 1000
	check_err $? "hash_buckets 1000 rejected"
	amt_check hash_buckets 1000
	ip -n "$NS" link del amt0 2>/dev/null
	log_test "hash_buckets need not be a power of two"
}

# test_bound <attribute> <max>: the attribute accepts <max> and rejects
# <max> + 1.
test_bound()
{
	local over=$(($2 + 1))

	RET=0
	amt_add "$1" "$2"
	check_err $? "$1 $2 rejected"
	amt_check "$1" "$2"
	ip -n "$NS" link del amt0 2>/dev/null
	amt_add "$1" "$over" 2>/dev/null
	check_fail $? "$1 $over accepted"
	ip -n "$NS" link del amt0 2>/dev/null
	log_test "$1 is bounded at $2"
}

require_command jq
if ! ip link help amt 2>&1 | grep -q hash_buckets; then
	echo "SKIP: iproute2 does not support the amt scaling attributes"
	exit "$ksft_skip"
fi

trap cleanup_all_ns EXIT
setup_ns NS || exit "$ksft_skip"
ip -n "$NS" link add eth-host type dummy
ip -n "$NS" link set eth-host up
ip -n "$NS" addr add 192.0.2.1/24 dev eth-host

probe_amt

test_defaults
test_override
test_hash_buckets_not_pow2
test_bound hash_buckets 4096
test_bound max_groups 4096
test_bound num_queues 32

exit "$EXIT_STATUS"
