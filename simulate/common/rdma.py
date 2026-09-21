from scapy.layers.l2 import Ether
from scapy.layers.inet import IP, UDP
from scapy.packet import Raw, Packet
from scapy.contrib.roce import BTH
from scapy.fields import XIntField, ByteField, BitField
from scapy.all import sendp
from simulate.common import config
from simulate.common.netlock import NetLockOp, NetLockPkt


class DETH(Packet):
    name = "DETH"
    fields_desc = [
        XIntField("q_key", 0),  # 32 bits
        ByteField("reserved", 0),  # 8 bits
        BitField("src_qpn", 0, 24),  # 24 bits
    ]


class RdmaNode:
    def __init__(self, mac_addr, ip_addr, iface):
        self.mac_addr = mac_addr
        self.ip_addr = ip_addr
        self.iface = iface
        pass

    def _build_pkt(
        self,
        dst_mac,
        dst_ip,
        dst_qpn,
        psn,
        src_qpn,
        q_key,
        netlock_pkt,
    ):
        return (
            Ether(src=self.mac_addr, dst=dst_mac)
            / IP(src=self.ip_addr, dst=dst_ip)
            / UDP(sport=config.RDMA_UDP_PORT, dport=config.RDMA_UDP_PORT, chksum=0)
            / BTH(
                opcode="UD_SEND_ONLY",
                padcount=0,
                dqpn=dst_qpn,
                psn=psn,
            )
            / DETH(
                q_key=q_key,
                src_qpn=src_qpn,
            )
            / netlock_pkt
        )

    def send_pkt(
        self, dst_mac, dst_ip, dst_qpn, psn, src_qpn, q_key, client_id, lock_id, txn_id,
        op=NetLockOp.ACQUIRED,
    ):

        netlock_pkt = Raw(
            load=NetLockPkt(op=op, client_id=client_id, lock_id=lock_id, txn_id=txn_id)
        )

        pkt = self._build_pkt(
            dst_mac=dst_mac,
            dst_ip=dst_ip,
            dst_qpn=dst_qpn,
            psn=psn,
            src_qpn=src_qpn,
            q_key=q_key,
            netlock_pkt=netlock_pkt,
        )

        sendp(pkt, iface=self.iface)
