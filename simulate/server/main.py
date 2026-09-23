from collections import deque
from dataclasses import dataclass, field

from scapy.all import sendp, sniff
from scapy.contrib.roce import BTH
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether

from simulate.common import config
from simulate.common.netlock import NetLockMode, NetLockOp, NetLockPkt
from simulate.common.rdma import DETH, RdmaNode
from simulate.common.utils import get_logger


@dataclass(frozen=True)
class Request:
    mac: str
    ip: str
    udp_port: int
    qpn: int
    client_id: int
    txn_id: int
    mode: int

    @property
    def owner_key(self):
        return (self.mac, self.ip, self.udp_port, self.qpn, self.client_id, self.txn_id)


@dataclass
class Lock:
    owner: Request
    waiters: deque = field(default_factory=deque)


class Server(RdmaNode):
    def __init__(
        self, mac_addr, ip_addr, iface, qpn=config.SERVER_QPN, q_key=config.Q_KEY
    ):
        super().__init__(mac_addr, ip_addr, iface)
        self.qpn = qpn
        self.q_key = q_key
        self.locks = {}
        self._psn = 0
        self.logger = get_logger("logs/server.log")

    def _grant(self, lock_id, request):
        packet = self._build_pkt(
            request.mac,
            request.ip,
            request.qpn,
            self._psn,
            self.qpn,
            self.q_key,
            NetLockPkt(
                op=NetLockOp.GRANT,
                mode=request.mode,
                client_id=request.client_id,
                lock_id=lock_id,
                txn_id=request.txn_id,
            ),
        )
        packet[UDP].dport = request.udp_port
        self._psn = (self._psn + 1) % (1 << 24)
        sendp(packet, iface=self.iface, verbose=False)
        self.logger.info(
            "Sent GRANT client_id=%s lock_id=%s txn_id=%s",
            request.client_id,
            lock_id,
            request.txn_id,
        )

    def _receive_request(self, packet):
        if not (Ether in packet and IP in packet and UDP in packet):
            return
        if (
            packet[Ether].dst.lower() != self.mac_addr.lower()
            or packet[IP].dst != self.ip_addr
            or packet[UDP].dport != config.RDMA_UDP_PORT
            or packet[IP].frag != 0
            or int(packet[IP].flags) & 1
        ):
            return
        payload = bytes(packet[UDP].payload)
        # Fixed simulation format: BTH(12), DETH(8), NetLock(10), pad(2), ICRC(4).
        if len(payload) != 36:
            return
        bth = BTH(payload)
        if bth.padcount != 2 or bth.version != 0:
            return
        deth = DETH(payload[12:20])
        netlock = NetLockPkt(payload[20:30])
        if (
            bth.opcode != 0x64
            or bth.dqpn != self.qpn
            or deth.q_key != self.q_key
            or netlock.op not in (NetLockOp.ACQUIRED, NetLockOp.RELEASE)
        ):
            return
        request = Request(
            packet[Ether].src.lower(),
            packet[IP].src,
            packet[UDP].sport,
            deth.src_qpn,
            netlock.client_id,
            netlock.txn_id,
            netlock.mode,
        )
        lock_id = netlock.lock_id
        if not 0 <= lock_id < config.NUM_LOCKS:
            return
        lock = self.locks.get(lock_id)
        if netlock.op == NetLockOp.ACQUIRED:
            self.logger.info(
                "Received ACQUIRE client_id=%s lock_id=%s txn_id=%s",
                request.client_id,
                lock_id,
                request.txn_id,
            )
            if request.mode not in (NetLockMode.SHARED, NetLockMode.EXCLUSIVE):
                return
            if lock is None:
                self.logger.info(
                    "Lock free; granting client_id=%s lock_id=%s txn_id=%s",
                    request.client_id,
                    lock_id,
                    request.txn_id,
                )
                self.locks[lock_id] = Lock(request)
                self._grant(lock_id, request)
            elif lock.owner.owner_key == request.owner_key:
                # Retransmission by the owner: re-send the grant.
                self.logger.info(
                    "Owner retried acquire; re-granting client_id=%s lock_id=%s txn_id=%s",
                    request.client_id,
                    lock_id,
                    request.txn_id,
                )
                self._grant(lock_id, lock.owner)
            elif not any(
                waiter.owner_key == request.owner_key for waiter in lock.waiters
            ):
                lock.waiters.append(request)
                self.logger.info(
                    "Queued ACQUIRE client_id=%s lock_id=%s txn_id=%s position=%s",
                    request.client_id,
                    lock_id,
                    request.txn_id,
                    len(lock.waiters),
                )
            else:
                self.logger.info(
                    "Already queued client_id=%s lock_id=%s txn_id=%s",
                    request.client_id,
                    lock_id,
                    request.txn_id,
                )
        elif lock is not None and lock.owner.owner_key == request.owner_key:
            self.logger.info(
                "Received owner RELEASE client_id=%s lock_id=%s txn_id=%s",
                request.client_id,
                lock_id,
                request.txn_id,
            )
            if lock.waiters:
                lock.owner = lock.waiters.popleft()
                self._grant(lock_id, lock.owner)
            else:
                del self.locks[lock_id]
                self.logger.info("Lock free lock_id=%s", lock_id)
        else:
            self.logger.warning(
                "Ignored non-owner RELEASE client_id=%s lock_id=%s txn_id=%s",
                request.client_id,
                lock_id,
                request.txn_id,
            )

    def start(self):
        sniff(iface=self.iface, store=False, prn=self._receive_request)
