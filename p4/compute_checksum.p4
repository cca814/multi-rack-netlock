#ifndef _NETLOCK_COMPUTE_CHECKSUM_P4
#define _NETLOCK_COMPUTE_CHECKSUM_P4

control NetLockComputeChecksum(inout headers_t headers,
                               inout metadata_t metadata) {
    apply {
        update_checksum(
            headers.ipv4.isValid(),
            {
                headers.ipv4.version,
                headers.ipv4.ihl,
                headers.ipv4.dscp,
                headers.ipv4.ecn,
                headers.ipv4.total_len,
                headers.ipv4.identification,
                headers.ipv4.flags,
                headers.ipv4.frag_offset,
                headers.ipv4.ttl,
                headers.ipv4.protocol,
                headers.ipv4.src_addr,
                headers.ipv4.dst_addr
            },
            headers.ipv4.hdr_checksum,
            HashAlgorithm.csum16
        );
    }
}

#endif
