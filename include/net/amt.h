/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Copyright (c) 2021 Taehee Yoo <ap420073@gmail.com>
 */
#ifndef _NET_AMT_H_
#define _NET_AMT_H_

#include <linux/siphash.h>
#include <linux/jhash.h>
#include <linux/hashtable.h>
#include <linux/netdevice.h>
#include <linux/rhashtable.h>
#include <net/gro_cells.h>
#include <net/rtnetlink.h>

enum amt_msg_type {
	AMT_MSG_DISCOVERY = 1,
	AMT_MSG_ADVERTISEMENT,
	AMT_MSG_REQUEST,
	AMT_MSG_MEMBERSHIP_QUERY,
	AMT_MSG_MEMBERSHIP_UPDATE,
	AMT_MSG_MULTICAST_DATA,
	AMT_MSG_TEARDOWN,
	__AMT_MSG_MAX,
};

#define AMT_MSG_MAX (__AMT_MSG_MAX - 1)

enum amt_ops {
	/* A*B */
	AMT_OPS_INT,
	/* A+B */
	AMT_OPS_UNI,
	/* A-B */
	AMT_OPS_SUB,
	/* B-A */
	AMT_OPS_SUB_REV,
	__AMT_OPS_MAX,
};

#define AMT_OPS_MAX (__AMT_OPS_MAX - 1)

enum amt_filter {
	AMT_FILTER_FWD,
	AMT_FILTER_D_FWD,
	AMT_FILTER_FWD_NEW,
	AMT_FILTER_D_FWD_NEW,
	AMT_FILTER_ALL,
	AMT_FILTER_NONE_NEW,
	AMT_FILTER_BOTH,
	AMT_FILTER_BOTH_NEW,
	__AMT_FILTER_MAX,
};

#define AMT_FILTER_MAX (__AMT_FILTER_MAX - 1)

enum amt_act {
	AMT_ACT_GMI,
	AMT_ACT_GMI_ZERO,
	AMT_ACT_GT,
	AMT_ACT_STATUS_FWD_NEW,
	AMT_ACT_STATUS_D_FWD_NEW,
	AMT_ACT_STATUS_NONE_NEW,
	__AMT_ACT_MAX,
};

#define AMT_ACT_MAX (__AMT_ACT_MAX - 1)

enum amt_status {
	AMT_STATUS_INIT,
	AMT_STATUS_SENT_DISCOVERY,
	AMT_STATUS_RECEIVED_DISCOVERY,
	AMT_STATUS_SENT_ADVERTISEMENT,
	AMT_STATUS_RECEIVED_ADVERTISEMENT,
	AMT_STATUS_SENT_REQUEST,
	AMT_STATUS_RECEIVED_REQUEST,
	AMT_STATUS_SENT_QUERY,
	AMT_STATUS_RECEIVED_QUERY,
	AMT_STATUS_SENT_UPDATE,
	AMT_STATUS_RECEIVED_UPDATE,
	__AMT_STATUS_MAX,
};

#define AMT_STATUS_MAX (__AMT_STATUS_MAX - 1)

/* Gateway events only */
enum amt_event {
	AMT_EVENT_NONE,
	AMT_EVENT_RECEIVE,
	AMT_EVENT_SEND_DISCOVERY,
	AMT_EVENT_SEND_REQUEST,
	__AMT_EVENT_MAX,
};

struct amt_header {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u8 type:4,
	   version:4;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u8 version:4,
	   type:4;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
} __packed;

struct amt_header_discovery {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u32	type:4,
		version:4,
		reserved:24;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u32	version:4,
		type:4,
		reserved:24;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32	nonce;
} __packed;

struct amt_header_advertisement {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u32	type:4,
		version:4,
		reserved:24;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u32	version:4,
		type:4,
		reserved:24;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32	nonce;
	__be32	ip4;
} __packed;

/* RFC 7450 §5.1.2 Relay Advertisement message — IPv6 form.
 *
 * Same fixed 4-byte header and 4-byte Discovery Nonce as the IPv4
 * variant (struct amt_header_advertisement above); the trailing
 * Relay Address field is 16 bytes instead of 4. Total wire size:
 * 4 + 4 + 16 = 24 bytes. Per §5.2 the form is selected from the
 * outer IP version, not from any in-header marker, so this is a
 * separate type rather than a union over amt_header_advertisement.
 */
struct amt_header_advertisement_v6 {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u32	type:4,
		version:4,
		reserved:24;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u32	version:4,
		type:4,
		reserved:24;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32		nonce;
	struct in6_addr	ip6;
} __packed;

struct amt_header_request {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u32	type:4,
		version:4,
		reserved1:7,
		p:1,
		reserved2:16;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u32	version:4,
		type:4,
		p:1,
		reserved1:7,
		reserved2:16;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32	nonce;
} __packed;

struct amt_header_membership_query {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u64	type:4,
		version:4,
		reserved:6,
		l:1,
		g:1,
		response_mac:48;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u64	version:4,
		type:4,
		g:1,
		l:1,
		reserved:6,
		response_mac:48;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32	nonce;
} __packed;

struct amt_header_membership_update {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u64	type:4,
		version:4,
		reserved:8,
		response_mac:48;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u64	version:4,
		type:4,
		reserved:8,
		response_mac:48;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
	__be32	nonce;
} __packed;

struct amt_header_mcast_data {
#if defined(__LITTLE_ENDIAN_BITFIELD)
	u16	type:4,
		version:4,
		reserved:8;
#elif defined(__BIG_ENDIAN_BITFIELD)
	u16	version:4,
		type:4,
		reserved:8;
#else
#error  "Please fix <asm/byteorder.h>"
#endif
} __packed;

struct amt_headers {
	union {
		struct amt_header_discovery discovery;
		struct amt_header_advertisement advertisement;
		struct amt_header_request request;
		struct amt_header_membership_query query;
		struct amt_header_membership_update update;
		struct amt_header_mcast_data data;
	};
} __packed;

struct amt_gw_headers {
	union {
		struct amt_header_discovery discovery;
		struct amt_header_request request;
		struct amt_header_membership_update update;
	};
} __packed;

struct amt_relay_headers {
	union {
		struct amt_header_advertisement advertisement;
		struct amt_header_membership_query query;
		struct amt_header_mcast_data data;
	};
} __packed;

union amt_addr {
	__be32			ip4;
#if IS_ENABLED(CONFIG_IPV6)
	struct in6_addr		ip6;
#endif
};

/* Upstream IGMPv3 / MLDv2 host-stack membership state. Sized for production
 * relay scale (thousands of active (S, G) tuples possible).
 */
#define AMT_UPSTREAM_HASH_BITS	10

/* One (S, G) of upstream interest. `want` is the DESIRED state: the
 * number of source nodes currently contributing interest (many gateways
 * may join the same (S, G)). `joined` is the ACTUAL state: whether the
 * kernel host stack currently holds the membership on the stream
 * socket. The reconciler worker converges joined toward (want > 0);
 * both fields are protected by amt->upstream_lock. Entries are freed
 * only by the reconciler (and the destructor, strictly after the
 * worker is cancelled), so the reconciler may drop upstream_lock
 * around the sleeping setsockopt while holding an entry pointer.
 */
struct amt_upstream_entry {
	struct hlist_node	node;
	union amt_addr		group;
	union amt_addr		source;
	bool			v6;
	bool			joined;
	int			want;
};

enum amt_upstream_op { AMT_UPSTREAM_JOIN, AMT_UPSTREAM_LEAVE };

struct amt_tunnel_list {
	struct list_head	list;
	/* Protect All resources under an amt_tunne_list */
	spinlock_t		lock;
	struct amt_dev		*amt;
	u32			nr_groups;
	u32			nr_sources;
	enum amt_status		status;
	struct delayed_work	gc_wq;
	__be16			source_port;
	/* Outer source address of the gateway endpoint, in the device's
	 * outer family (amt_v6()).
	 */
	union amt_addr		addr;
	__be32			nonce;
	siphash_key_t		key;
	u64			mac:48,
				reserved:16;
	struct rcu_head		rcu;
	/* This tunnel's entries in amt->groups_rhl, under lock */
	struct list_head	groups;
};

/* RFC 3810
 *
 * When the router is in EXCLUDE mode, the router state is represented
 * by the notation EXCLUDE (X,Y), where X is called the "Requested List"
 * and Y is called the "Exclude List".  All sources, except those from
 * the Exclude List, will be forwarded by the router
 */
enum amt_source_status {
	AMT_SOURCE_STATUS_NONE,
	/* Node of Requested List */
	AMT_SOURCE_STATUS_FWD,
	/* Node of Exclude List */
	AMT_SOURCE_STATUS_D_FWD,
};

/* protected by gnode->lock */
struct amt_source_node {
	struct hlist_node	node;
	struct amt_group_node	*gnode;
	struct delayed_work     source_timer;
	union amt_addr		source_addr;
	enum amt_source_status	status;
#define AMT_SOURCE_OLD	0
#define AMT_SOURCE_NEW	1
	u8			flags;
	/* Whether this source node currently contributes one count of
	 * upstream host-stack (S, G) interest (amt_upstream_entry.want).
	 * Set at most once per node lifetime on the first FWD_NEW while
	 * the group is INCLUDE; cleared exactly once when the node is
	 * destroyed. Makes the per-report FWD_NEW re-mark of surviving
	 * sources idempotent and pairs every recorded join with exactly
	 * one release, regardless of the group's filter mode at release
	 * time.
	 */
	bool			upstream_joined;
	struct rcu_head		rcu;
};

/* Protected by amt_tunnel_list->lock */
struct amt_group_node {
	struct amt_dev		*amt;
	/* Key in amt->groups_rhl; the hosts that joined a group through
	 * one tunnel share a key.
	 */
	struct_group_tagged(amt_gnode_key, key,
		struct amt_tunnel_list	*tunnel_list;
		union amt_addr		group_addr;
		bool			v6;
	);
	union amt_addr		host_addr;
	u8			filter_mode;
	u32			nr_sources;
	struct list_head	tunnel_node;
	struct rhlist_head	rhlnode;
	struct delayed_work     group_timer;
	struct rcu_head		rcu;
	struct hlist_head	sources[];
};

#define AMT_MAX_EVENTS	16
struct amt_events {
	enum amt_event event;
	struct sk_buff *skb;
};

struct amt_dev {
	struct net_device       *dev;
	struct net_device       *stream_dev;
	struct net		*net;
	/* Global lock for amt device */
	spinlock_t		lock;
	/* Used only in relay mode */
	struct list_head        tunnel_list;
	/* Groups joined through any tunnel, keyed by amt_gnode_key */
	struct rhltable		groups_rhl;
	struct gro_cells	gro_cells;

	/* Protected by RTNL */
	struct delayed_work     discovery_wq;
	/* Protected by RTNL */
	struct delayed_work     req_wq;
	/* Protected by RTNL */
	struct delayed_work     secret_wq;
	struct work_struct	event_wq;
	/* AMT status */
	enum amt_status		status;
	/* Generated key */
	siphash_key_t		key;
	struct sock	  __rcu *sk;
	u32			max_groups;
	u32			max_sources;
	u32			hash_buckets;
	u32			hash_seed;
	/* Default 128 */
	u32                     max_tunnels;
	/* Default 128 */
	u32                     nr_tunnels;
	/* Gateway or Relay mode */
	u32                     mode;
	/* Default 2268 */
	__be16			relay_port;
	/* Default 2268 */
	__be16			gw_port;
	/* Outer local ip */
	__be32			local_ip;
	/* Outer local ipv6 (in6addr_any when v4 mode; mutually exclusive with local_ip) */
	struct in6_addr		local_ipv6;
	/* Outer remote ip */
	__be32			remote_ip;
	/* Outer remote ipv6 (learned from the v6 Relay Advertisement;
	 * in6addr_any in v4 mode, mutually exclusive with remote_ip)
	 */
	struct in6_addr		remote_ipv6;
	/* Publishes remote_ipv6, which is too wide for a single access */
	seqlock_t		remote_ipv6_lock;
	/* Outer discovery ip */
	__be32			discovery_ip;
	/* Outer discovery ipv6 (v6 gateway only; in6addr_any in v4 mode,
	 * mutually exclusive with discovery_ip)
	 */
	struct in6_addr		discovery_ipv6;
	/* Only used in gateway mode */
	__be32			nonce;
	/* Gateway sent request and received query */
	bool			ready4;
	bool			ready6;
	u8			req_cnt;
	u8			qi;
	u64			qrv;
	u64			qri;
	/* Used only in gateway mode */
	u64			mac:48,
				reserved:16;
	/* AMT gateway side message handler queue */
	struct amt_events	events[AMT_MAX_EVENTS];
	u8			event_idx;
	u8			nr_events;

	/* Upstream IGMPv3/MLDv2 host-stack membership state (relay mode).
	 *
	 * Relay mode mirrors gateway (S, G) interest as host-stack
	 * memberships on the underlying stream_dev via setsockopt on
	 * stream_sock_v{4,6}. The upstream table records DESIRED interest
	 * (amt_upstream_entry.want, one count per contributing source
	 * node) next to ACTUAL host-stack state (.joined); upstream_work
	 * is a reconciler that converges actual toward desired in process
	 * context, so the rtnl_lock taken internally by the IGMP/MLD
	 * setsockopt paths (on the kernels we target) is never nested
	 * inside a caller-held lock. A failed emit leaves the entry
	 * unconverged and arms a delayed retry.
	 *
	 * upstream_lock protects the table; it is bh because desired
	 * state changes arrive from the softirq decap path. The
	 * reconciler is the only context that frees entries (destructor
	 * aside, which runs strictly after the work is cancelled), so it
	 * may drop upstream_lock around the sleeping setsockopt while
	 * holding an entry pointer. upstream_active tracks whether
	 * stream_dev is usable (cleared on NETDEV_DOWN, set on open/UP);
	 * it pauses reconciliation but never desired-state recording, so
	 * releases during a down window or device stop are not lost.
	 */
	spinlock_t		upstream_lock;
	DECLARE_HASHTABLE(upstream, AMT_UPSTREAM_HASH_BITS);
	bool			upstream_active;
	struct delayed_work	upstream_work;
	struct socket		*stream_sock_v4;
	struct socket		*stream_sock_v6;
	atomic_t		upstream_setsockopt_slow_count;
};

#define AMT_TOS			0xc0
#define AMT_IPHDR_OPTS		4
#define AMT_IP6HDR_OPTS		8
#define AMT_GC_INTERVAL		(30 * 1000)
#define AMT_MAX_GROUP		32
#define AMT_MAX_SOURCE		128
#define AMT_HSIZE_SHIFT		8
#define AMT_HSIZE		(1 << AMT_HSIZE_SHIFT)

#define AMT_DISCOVERY_TIMEOUT	5000
#define AMT_INIT_REQ_TIMEOUT	1
#define AMT_INIT_QUERY_INTERVAL	125
#define AMT_MAX_REQ_TIMEOUT	120
#define AMT_MAX_REQ_COUNT	3
#define AMT_SECRET_TIMEOUT	60000
#define IANA_AMT_UDP_PORT	2268
#define AMT_MAX_TUNNELS         128
#define AMT_MAX_REQS		128
/* Upper bound on TX/RX queues an amt netdev can be allocated with.
 * The actual live queue count is set per-link via IFLA_AMT_NUM_QUEUES
 * with a default of 1 (backwards-compatible). Picked to match a
 * reasonable upper bound on per-relay parallelism; bigger numbers
 * just waste alloc memory (a few hundred bytes per reserved slot).
 */
#define AMT_MAX_QUEUES		32
#define AMT_GW_HLEN (sizeof(struct iphdr) + \
		     sizeof(struct udphdr) + \
		     sizeof(struct amt_gw_headers))
/* IPv6-outer gateway headroom: the outer header is a struct ipv6hdr. */
#define AMT_GW_HLEN6 (sizeof(struct ipv6hdr) + \
		      sizeof(struct udphdr) + \
		      sizeof(struct amt_gw_headers))
#define AMT_RELAY_HLEN (sizeof(struct iphdr) + \
		     sizeof(struct udphdr) + \
		     sizeof(struct amt_relay_headers))

static inline bool netif_is_amt(const struct net_device *dev)
{
	return dev->rtnl_link_ops && !strcmp(dev->rtnl_link_ops->kind, "amt");
}

static inline u64 amt_gmi(const struct amt_dev *amt)
{
	return ((amt->qrv * amt->qi) + amt->qri) * 1000;
}

#endif /* _NET_AMT_H_ */
