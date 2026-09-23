#ifndef _NETLOCK_PARSER_P4
#define _NETLOCK_PARSER_P4

#include "include/const.p4"
#include "include/header.p4"

parser NetLockParser(packet_in packet,
                     out headers_t headers,
                     inout metadata_t metadata,
                     inout standard_metadata_t standard_metadata) {
    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(headers.ethernet);
        transition select(headers.ethernet.ether_type) {
            ETHERTYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(headers.ipv4);
        transition select(headers.ipv4.protocol) {
            IP_PROTO_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(headers.udp);
        transition select(headers.udp.dst_port) {
            UDP_PORT_ROCEV2: parse_bth;
            default: accept;
        }
    }

    state parse_bth {
        packet.extract(headers.bth);
        transition parse_deth;
    }

    state parse_deth {
        packet.extract(headers.deth);
        transition parse_netlock;
    }

    state parse_netlock {
        packet.extract(headers.netlock);
        transition parse_roce_padding;
    }

    state parse_roce_padding {
        packet.extract(headers.roce_padding);
        transition parse_icrc;
    }

    state parse_icrc {
        packet.extract(headers.icrc);
        transition accept;
    }
}

#endif
