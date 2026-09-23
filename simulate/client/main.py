import random
from queue import Empty, Queue
from threading import Event
from time import monotonic, sleep

from scapy.all import AsyncSniffer, conf
from scapy.contrib.roce import BTH
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether

from simulate.common import config
from simulate.common.config import Scenario
from simulate.common.netlock import NetLockOp, NetLockPkt
from simulate.common.rdma import DETH, RdmaNode
from simulate.common.utils import get_logger

NUM_OF_LOCK_TO_ACQUIRED = 10000
HOLD_TIME = 1.0  # Seconds to hold each granted lock.


class Client(RdmaNode):
    def __init__(
        self,
        mac_addr,
        ip_addr,
        iface,
        server_ip,
        server_mac,
        server_qpn,
        q_key,
        scenario,
        client_id,
    ):
        super().__init__(mac_addr, ip_addr, iface)
        self.server_ip = server_ip
        self.server_mac = server_mac
        self.server_qpn = server_qpn
        self.q_key = q_key
        self.client_id = client_id
        self.scenario = scenario
        self._next_txn_id = 0
        self.logger = get_logger("logs/client.log")

    def _receive_grant(self, pkt):
        if not (Ether in pkt and IP in pkt and UDP in pkt):
            return
        if (
            pkt[Ether].dst.lower() != self.mac_addr.lower()
            or pkt[IP].dst != self.ip_addr
            or pkt[UDP].dport != config.RDMA_UDP_PORT
        ):
            return
        payload = bytes(pkt[UDP].payload)
        if len(payload) != 36:
            return
        bth = BTH(payload)
        if bth.padcount != 2 or bth.version != 0:
            return
        deth = DETH(payload[12:20])
        grant = NetLockPkt(payload[20:30])
        if (
            bth.opcode == 0x64
            and bth.dqpn == config.CLIENT_QPN
            and deth.q_key == self.q_key
            and grant.op == NetLockOp.GRANT
            and grant.client_id == self.client_id
        ):
            self.logger.info(
                "Received GRANT client_id=%s lock_id=%s txn_id=%s",
                self.client_id, grant.lock_id, grant.txn_id,
            )
            self._replies.put(grant)

    def start(self, reply_timeout=5.0):
        if self.scenario != Scenario.RANDOM:
            raise NotImplementedError
        if reply_timeout <= 0:
            raise ValueError("reply_timeout must be positive")
        if HOLD_TIME < 0:
            raise ValueError("HOLD_TIME must be nonnegative")

        self._replies = Queue()
        ready = Event()
        grants = []
        # Open synchronously so interface/permission errors reach the caller.
        capture = conf.L2listen(iface=self.iface)
        sniffer = AsyncSniffer(
            opened_socket=capture,
            store=False,
            prn=self._receive_grant,
            started_callback=ready.set,
        )
        try:
            sniffer.start()
            if not ready.wait(timeout=3):
                raise RuntimeError(f"Capture did not start on {self.iface}")

            for _ in range(NUM_OF_LOCK_TO_ACQUIRED):
                lock_id = random.randrange(config.NUM_LOCKS)
                txn_id = self._next_txn_id
                self._next_txn_id = (txn_id + 1) % 65536
                client_id = self.client_id

                self.logger.info(
                    "Sending ACQUIRE client_id=%s lock_id=%s txn_id=%s",
                    client_id, lock_id, txn_id,
                )
                self.send_pkt(
                    self.server_mac,
                    self.server_ip,
                    self.server_qpn,
                    1,
                    config.CLIENT_QPN,
                    self.q_key,
                    client_id,
                    lock_id,
                    txn_id,
                )

                deadline = monotonic() + reply_timeout
                while True:
                    remaining = deadline - monotonic()
                    if remaining <= 0:
                        raise TimeoutError(
                            f"Timed out waiting for grant: lock_id={lock_id}, txn_id={txn_id}"
                        )
                    try:
                        grant = self._replies.get(timeout=remaining)
                    except Empty:
                        raise TimeoutError(
                            f"Timed out waiting for grant: lock_id={lock_id}, txn_id={txn_id}"
                        ) from None
                    if grant.lock_id == lock_id and grant.txn_id == txn_id:
                        break

                grants.append(grant)
                try:
                    self.logger.info(
                        "Holding lock client_id=%s lock_id=%s txn_id=%s; release in %s seconds",
                        client_id, lock_id, txn_id, HOLD_TIME,
                    )
                    sleep(HOLD_TIME)
                finally:
                    # Release the same ownership tuple, including on Ctrl+C.
                    self.logger.info(
                        "Sending RELEASE client_id=%s lock_id=%s txn_id=%s",
                        client_id, lock_id, txn_id,
                    )
                    self.send_pkt(
                        self.server_mac,
                        self.server_ip,
                        self.server_qpn,
                        1,
                        config.CLIENT_QPN,
                        self.q_key,
                        client_id,
                        lock_id,
                        txn_id,
                        op=NetLockOp.RELEASE,
                    )
            return grants
        finally:
            try:
                if sniffer.running and ready.is_set():
                    sniffer.stop()
            finally:
                capture.close()
