#ifndef _NETLOCK_INGRESS_P4_
#define _NETLOCK_INGRESS_P4_

#include "lock_engine.p4"

control NetLockIngress(inout headers_t headers,
                       inout metadata_t metadata,
                       inout standard_metadata_t standard_metadata) {
    NetLockEngine() lock_engine;
    bit<1> use_lock_engine;
    bit<1> config_ready;

    action set_node_config(MAC_ADDR_T switch_mac_addr,
                           MAC_ADDR_T server_mac_addr,
                           IPV4_ADDR_T server_ip_addr,
                           PORT_T to_server_port,
                           QP_T server_qp) {
        metadata.node_config.switch_mac_addr = switch_mac_addr;
        metadata.node_config.server_mac_addr = server_mac_addr;
        metadata.node_config.server_ip_addr = server_ip_addr;
        metadata.node_config.to_server_port = to_server_port;
        metadata.node_config.server_qp = server_qp;
        config_ready = 1;
    }

    table node_config {
        actions = {
            set_node_config;
            NoAction;
        }
        default_action = NoAction();
    }

    action forward_to_server() {
        use_lock_engine = 0;
    }

    action send_to_server() {
        headers.ethernet.src_addr = metadata.node_config.switch_mac_addr;
        headers.ethernet.dst_addr = metadata.node_config.server_mac_addr;
        headers.ipv4.dst_addr = metadata.node_config.server_ip_addr;
        headers.ipv4.ttl = headers.ipv4.ttl - 1;
        headers.bth.dest_qp = metadata.node_config.server_qp;
        headers.udp.checksum = 0;
        standard_metadata.egress_spec = metadata.node_config.to_server_port;
    }

    action set_action() {
        use_lock_engine = 1;
    }

    action send_grant() {
        headers.ethernet.src_addr = metadata.node_config.switch_mac_addr;
        headers.ethernet.dst_addr = metadata.engine.client.mac_addr;
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
        standard_metadata.egress_spec = metadata.engine.client.port;
    }

    table lock_id_to_action {
        key = { headers.netlock.lock_id: exact; }
        actions = {
            set_action;
            forward_to_server;
        }
        size = 1024;
        default_action = forward_to_server();
    }

    apply {
        use_lock_engine = 0;
        config_ready = 0;
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
                lock_id_to_action.apply();
                if (use_lock_engine == 1) {
                    lock_engine.apply(headers, metadata, standard_metadata);
                    if (metadata.engine.engine_action == NETLOCK_ENGINE_ACTION_GRANT &&
                        metadata.engine.grant == 1) {
                        send_grant();
                    } else {
                        mark_to_drop(standard_metadata);
                    }
                } else {
                    if (headers.ipv4.ttl <= 1) {
                        mark_to_drop(standard_metadata);
                    } else {
                        send_to_server();
                    }
                }
            }
        }
    }
}

#endif
