#ifndef _NETLOCK_HEADER_P4_
#define _NETLOCK_HEADER_P4_

typedef bit<48> MAC_ADDR_T;
typedef bit<32> IPV4_ADDR_T;
typedef bit<9> PORT_T;
typedef bit<24> QP_T;

header ethernet_h {
    MAC_ADDR_T dst_addr;
    MAC_ADDR_T src_addr;
    bit<16> ether_type;
}

header ipv4_h {
    bit<4> version;
    bit<4> ihl;
    bit<6> dscp;
    bit<2> ecn;
    bit<16> total_len;
    bit<16> identification;
    bit<3> flags;
    bit<13> frag_offset;
    bit<8> ttl;
    bit<8> protocol;
    bit<16> hdr_checksum;
    IPV4_ADDR_T src_addr;
    IPV4_ADDR_T dst_addr;
}

header udp_h {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> len;
    bit<16> checksum;
}

// Infiniband Base Transport Header
header bth_h {
    bit<8> opcode;
    bit<1> se;  // solicited event
    bit<1> mig_req;  // migration request
    bit<2> pad_count;
    bit<4> tranport_header_version;
    bit<16> p_key;
    bit<8> reserved_1;
    QP_T dest_qp;
    bit<1> a_req;   // acknowledge request
    bit<7> reserved_2;
    bit<24> psn;
}

// Datagram extended Transport Header
header deth_h {
    bit<32> q_key;
    bit<8> reserved;
    bit<24> src_qpn;
}

header netlock_h {
    bit<8> op;
    bit<8> mode;
    bit<16> client_id;
    bit<32> lock_id;
    bit<16> txn_id;
}

header icrc_h {
    bit<32> value;
}

struct headers_t {
    ethernet_h ethernet;
    ipv4_h ipv4;
    udp_h udp;
    bth_h bth;
    deth_h deth;
    netlock_h netlock;
    icrc_h icrc;
}

// metadata
struct node_config_t {
    MAC_ADDR_T switch_mac_addr;
}

// Endpoint and request identity retained while a client waits for a lock.
struct lock_client_t {
    PORT_T port;
    MAC_ADDR_T mac_addr;
    IPV4_ADDR_T ip_addr;
    bit<16> udp_port;
    QP_T qp;
    bit<16> client_id;
    bit<16> txn_id;
    bit<8> mode;
}

struct lock_engine_metadata_t {
    bit<8> engine_action;
    bit<1> grant;
    // Valid only when grant == 1; may describe a previously queued client.
    lock_client_t client;
}

struct metadata_t {
    node_config_t node_config;
    lock_engine_metadata_t engine;
}

#endif
