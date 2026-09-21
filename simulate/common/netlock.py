from enum import IntEnum

from scapy.fields import ByteField, IntField, ShortField
from scapy.packet import Packet


class NetLockOp(IntEnum):
    ACQUIRED = 1
    RELEASE = 2
    GRANT = 3
    DRAIN = 4


class NetLockMode(IntEnum):
    FREE = 1
    SHARED = 2
    EXCLUSIVE = 3


class NetLockState(IntEnum):
    HOT = 1
    COLD = 2
    MIG_TO_SWITCH = 3
    MIG_TO_SERVER = 4


class NetLockPkt(Packet):
    name = "NetLock"
    fields_desc = [
        ByteField("op", NetLockOp.ACQUIRED),
        ByteField("mode", NetLockMode.SHARED),
        ShortField("client_id", 101),
        IntField("lock_id", 0x1234),
        ShortField("txn_id", 5001),
    ]
