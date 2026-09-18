#ifndef _NETLOCK_LOCK_ENGINE_P4_
#define _NETLOCK_LOCK_ENGINE_P4_

#include "include/const.p4"
#include "include/header.p4"
#include "include/register.p4"

control NetLockEngine(in headers_t headers,
                      inout metadata_t metadata,
                      in standard_metadata_t standard_metadata) {
    bit<1> owned;
    bit<32> owner;
    bit<32> head;
    bit<32> tail;
    bit<32> count;
    bit<32> slot;
    bit<32> request_owner;
    bit<169> client;

    apply {
        client = 0;
        metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_NONE;
        metadata.engine.grant = 0;
        metadata.engine.client.port = 0;
        metadata.engine.client.mac_addr = 0;
        metadata.engine.client.ip_addr = 0;
        metadata.engine.client.udp_port = 0;
        metadata.engine.client.qp = 0;
        metadata.engine.client.client_id = 0;
        metadata.engine.client.txn_id = 0;
        metadata.engine.client.mode = 0;

        if (headers.ethernet.isValid() && headers.ipv4.isValid() &&
            headers.udp.isValid() && headers.deth.isValid() &&
            headers.netlock.isValid() &&
            (headers.netlock.op == NETLOCK_OP_ACQUIRED ||
             headers.netlock.op == NETLOCK_OP_RELEASE)) {
            if (headers.netlock.lock_id >= NETLOCK_MAX_LOCKS) {
                metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_INVALID_LOCK;
            } else {
                request_owner = headers.netlock.client_id ++ headers.netlock.txn_id;
                @atomic {
                    lock_owned.read(owned, headers.netlock.lock_id);
                    lock_queue_count.read(count, headers.netlock.lock_id);

                    if (headers.netlock.op == NETLOCK_OP_ACQUIRED) {
                        client = standard_metadata.ingress_port ++
                                 headers.ethernet.src_addr ++ headers.ipv4.src_addr ++
                                 headers.udp.src_port ++ headers.deth.src_qpn ++
                                 headers.netlock.client_id ++ headers.netlock.txn_id ++
                                 headers.netlock.mode;
                        if (owned == 0 && count == 0) {
                            lock_owned.write(headers.netlock.lock_id, 1);
                            lock_owner.write(headers.netlock.lock_id, request_owner);
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_GRANT;
                            metadata.engine.grant = 1;
                        } else if (count < NETLOCK_QUEUE_DEPTH) {
                            lock_queue_tail.read(tail, headers.netlock.lock_id);
                            slot = headers.netlock.lock_id * NETLOCK_QUEUE_DEPTH + tail;
                            lock_waiters.write(slot, client);
                            tail = tail + 1;
                            if (tail == NETLOCK_QUEUE_DEPTH) {
                                tail = 0;
                            }
                            lock_queue_tail.write(headers.netlock.lock_id, tail);
                            lock_queue_count.write(headers.netlock.lock_id, count + 1);
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_ENQUEUE;
                        } else {
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_QUEUE_FULL;
                        }
                    } else {
                        lock_owner.read(owner, headers.netlock.lock_id);
                        if (owned == 0 || owner != request_owner) {
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_INVALID_RELEASE;
                        } else if (count != 0) {
                            lock_queue_head.read(head, headers.netlock.lock_id);
                            slot = headers.netlock.lock_id * NETLOCK_QUEUE_DEPTH + head;
                            lock_waiters.read(client, slot);
                            head = head + 1;
                            if (head == NETLOCK_QUEUE_DEPTH) {
                                head = 0;
                            }
                            lock_queue_head.write(headers.netlock.lock_id, head);
                            lock_queue_count.write(headers.netlock.lock_id, count - 1);
                            lock_owner.write(headers.netlock.lock_id, client[39:8]);
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_GRANT;
                            metadata.engine.grant = 1;
                        } else {
                            lock_owned.write(headers.netlock.lock_id, 0);
                            lock_owner.write(headers.netlock.lock_id, 0);
                            metadata.engine.engine_action = NETLOCK_ENGINE_ACTION_RELEASE;
                        }
                    }
                }

                if (metadata.engine.grant == 1) {
                    metadata.engine.client.port = client[168:160];
                    metadata.engine.client.mac_addr = client[159:112];
                    metadata.engine.client.ip_addr = client[111:80];
                    metadata.engine.client.udp_port = client[79:64];
                    metadata.engine.client.qp = client[63:40];
                    metadata.engine.client.client_id = client[39:24];
                    metadata.engine.client.txn_id = client[23:8];
                    metadata.engine.client.mode = client[7:0];
                }
            }
        }
    }
}

#endif
