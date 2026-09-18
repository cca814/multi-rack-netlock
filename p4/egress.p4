#ifndef _NETLOCK_EGRESS_P4
#define _NETLOCK_EGRESS_P4

control NetLockEgress(inout headers_t headers,
                      inout metadata_t metadata,
                      inout standard_metadata_t standard_metadata) {
    bit<32> icrc;

    // Fixed parsed layout: IPv4 / UDP / BTH / DETH / NetLock / ICRC.
    // No IPv4 options, additional payload, or RoCE padding are supported yet.
    // When extending the parser, include all payload and padding bytes here.
    action write_icrc() {
        hash(icrc, HashAlgorithm.crc32, (bit<32>) 0,
            {
                // Pseudo-LRH followed by invariant IPv4/UDP/BTH fields.
                64w0xffffffffffffffff,
                headers.ipv4.version,
                headers.ipv4.ihl,
                8w0xff, // DSCP and ECN
                headers.ipv4.total_len,
                headers.ipv4.identification,
                headers.ipv4.flags,
                headers.ipv4.frag_offset,
                8w0xff, // TTL
                headers.ipv4.protocol,
                16w0xffff, // IPv4 checksum
                headers.ipv4.src_addr,
                headers.ipv4.dst_addr,
                headers.udp.src_port,
                headers.udp.dst_port,
                headers.udp.len,
                16w0xffff, // UDP checksum
                headers.bth.opcode,
                headers.bth.se,
                headers.bth.mig_req,
                headers.bth.pad_count,
                headers.bth.tranport_header_version,
                headers.bth.p_key,
                8w0xff, // BTH reserved/FECN/BECN byte
                headers.bth.dest_qp,
                headers.bth.a_req,
                headers.bth.reserved_2,
                headers.bth.psn,
                headers.deth.q_key,
                headers.deth.reserved,
                headers.deth.src_qpn,
                headers.netlock.op,
                headers.netlock.mode,
                headers.netlock.client_id,
                headers.netlock.lock_id,
                headers.netlock.txn_id
            },
            // hash uses base + CRC % max; 2^32 preserves every CRC32 value.
            64w0x100000000);

        // CRC32 is transmitted least-significant byte first; P4 emits bit<32>
        // most-significant byte first, so reverse the bytes before deparsing.
        headers.icrc.value = icrc[7:0] ++ icrc[15:8] ++
                            icrc[23:16] ++ icrc[31:24];
    }

    apply {
        // Keep this call after any future egress packet modifications.
        if (headers.ipv4.isValid() && headers.udp.isValid() &&
            headers.bth.isValid() && headers.deth.isValid() &&
            headers.netlock.isValid() && headers.icrc.isValid()) {
            write_icrc();
        }
    }
}

#endif
