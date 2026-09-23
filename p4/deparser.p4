#ifndef _NETLOCK_DEPARSER_P4
#define _NETLOCK_DEPARSER_P4

control NetLockDeparser(packet_out packet,
                        in headers_t headers) {
    apply {
        packet.emit(headers.ethernet);
        packet.emit(headers.ipv4);
        packet.emit(headers.udp);
        packet.emit(headers.bth);
        packet.emit(headers.deth);
        packet.emit(headers.netlock);
        packet.emit(headers.roce_padding);
        packet.emit(headers.icrc);
    }
}

#endif