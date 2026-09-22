#ifndef _NETLOCK_INGRESS_P4_
#define _NETLOCK_INGRESS_P4_

#include "lock_engine.p4"

control NetLockIngress(inout headers_t headers,
                       inout metadata_t metadata,
                       inout standard_metadata_t standard_metadata) {
    NetLockEngine() lock_engine;
    bit<1> use_lock_engine;
    bit<1> config_ready;
    bit<1> route_ready;

    action set_node_config(MAC_ADDR_T switch_mac_addr) {
        metadata.node_config.switch_mac_addr = switch_mac_addr;
        config_ready = 1;
    }

    table node_config {
        actions = {
            set_node_config;
            NoAction;
        }
        default_action = NoAction();
    }

    action route_packet() {
        use_lock_engine = 0;
    }

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action forward(MAC_ADDR_T next_hop_mac, PORT_T port) {
        headers.ethernet.src_addr = metadata.node_config.switch_mac_addr;
        headers.ethernet.dst_addr = next_hop_mac;
        headers.udp.checksum = 0;
        standard_metadata.egress_spec = port;
    }

    // All requests and replies use the same destination lookup.
    table ipv4_forward {
        key = { headers.ipv4.dst_addr: exact; }
        actions = {
            forward;
            drop;
        }
        size = 1024;
        const default_action = drop();
    }

    action set_action() {
        use_lock_engine = 1;
    }

    action prepare_grant() {
        headers.ipv4.src_addr = headers.ipv4.dst_addr;
        headers.ipv4.dst_addr = metadata.engine.client.ip_addr;
        headers.ipv4.ttl = 64;
        headers.udp.src_port = headers.udp.dst_port;
        headers.udp.dst_port = metadata.engine.client.udp_port;
        headers.udp.checksum = 0;
        headers.deth.src_qpn = headers.bth.dest_qp;
        headers.bth.dest_qp = metadata.engine.client.qp;
        headers.netlock.op = NETLOCK_OP_GRANT;
        headers.netlock.client_id = metadata.engine.client.client_id;
        headers.netlock.txn_id = metadata.engine.client.txn_id;
        headers.netlock.mode = metadata.engine.client.mode;
    }

    table lock_id_to_action {
        key = { headers.netlock.lock_id: exact; }
        actions = {
            set_action;
            route_packet;
        }
        size = 1024;
        default_action = route_packet();
    }

    apply {
        use_lock_engine = 0;
        config_ready = 0;
        route_ready = 1;
        metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_NONE;
        metadata.engine.grant = 0;

        if (standard_metadata.parser_error != error.NoError ||
            !headers.ethernet.isValid() || !headers.ipv4.isValid() ||
            !headers.udp.isValid() || !headers.bth.isValid() ||
            !headers.deth.isValid() || !headers.netlock.isValid() ||
            !headers.icrc.isValid() || headers.ipv4.version != 4 ||
            headers.ipv4.ihl != 5 || headers.ipv4.frag_offset != 0 ||
            headers.ipv4.flags[0:0] != 0) {
            mark_to_drop(standard_metadata);
        } else {
            node_config.apply();
            if (config_ready == 0) {
                mark_to_drop(standard_metadata);
            } else {
                // Only requests can enter the engine. In particular, a GRANT
                // for a locally managed lock must still be routed normally.
                if (headers.netlock.op == NETLOCK_OP_ACQUIRED ||
                    headers.netlock.op == NETLOCK_OP_RELEASE) {
                    lock_id_to_action.apply();
                }
                if (use_lock_engine == 1) {
                    lock_engine.apply(headers, metadata, standard_metadata);
                    if (metadata.engine.engine_action == NETLOCK_ENGINE_ACTION_GRANT &&
                        metadata.engine.grant == 1) {
                        prepare_grant();
                    } else {
                        // Queued acquires and releases without a waiter are
                        // consumed locally; they must not fall through to routing.
                        route_ready = 0;
                    }
                }

                if (route_ready == 0 ||
                    (use_lock_engine == 0 && headers.ipv4.ttl <= 1)) {
                    mark_to_drop(standard_metadata);
                } else {
                    // Transit packets lose one hop. Locally generated grants
                    // keep the initial TTL set by prepare_grant().
                    if (use_lock_engine == 0) {
                        headers.ipv4.ttl = headers.ipv4.ttl - 1;
                    }
                    ipv4_forward.apply();
                }
            }
        }
    }
}

#endif
