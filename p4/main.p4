#include <core.p4>
#include <v1model.p4>

#include "include/const.p4"
#include "include/header.p4"
#include "ingress.p4"
#include "egress.p4"
#include "compute_checksum.p4"
#include "deparser.p4"
#include "parser.p4"
#include "verify_checksum.p4"



V1Switch(
    NetLockParser(),
    NetLockVerifyChecksum(),
    NetLockIngress(),
    NetLockEgress(),
    NetLockComputeChecksum(),
    NetLockDeparser()
) main;
