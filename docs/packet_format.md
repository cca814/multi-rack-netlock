# NetLock Packet Format

This document describes the fixed packet layout currently implemented in
[header.p4](../p4/include/header.p4) and [parser.p4](../p4/parser.p4).

```text
Ethernet | IPv4 | UDP | BTH | DETH | NetLock | ICRC
   14       20     8    12     8      10       4    bytes
```

The layout totals **76 bytes**, excluding Ethernet preamble and FCS. Multi-byte
fields use network byte order (big-endian), except the ICRC, which is emitted
least-significant byte first.

## Header layout

Offsets are measured from the start of the Ethernet header.

| Header   | Byte offset | Size     | Main fields                                                 |
| -------- | ----------- | -------- | ----------------------------------------------------------- |
| Ethernet | 0           | 14 bytes | Destination MAC, source MAC, EtherType                      |
| IPv4     | 14          | 20 bytes | Source/destination IP, length, TTL, protocol, checksum      |
| UDP      | 34          | 8 bytes  | Source/destination port, length, checksum                   |
| BTH      | 42          | 12 bytes | Transport opcode, flags, partition key, destination QP, PSN |
| DETH     | 54          | 8 bytes  | Queue key, reserved byte, source QP                         |
| NetLock  | 62          | 10 bytes | Operation, mode, client ID, lock ID, transaction ID         |
| ICRC     | 72          | 4 bytes  | Invariant CRC                                               |

Incoming NetLock requests use Ethernet EtherType `0x0800`, IPv4 protocol `17`
(UDP), and UDP destination port `4791`.

## NetLock header

Offsets below are relative to the start of the NetLock header.

| Field       | Byte offset | Width   | Meaning                |
| ----------- | ----------- | ------- | ---------------------- |
| `op`        | 0           | 8 bits  | NetLock operation      |
| `mode`      | 1           | 8 bits  | Requested lock mode    |
| `client_id` | 2           | 16 bits | Client identifier      |
| `lock_id`   | 4           | 32 bits | Lock identifier        |
| `txn_id`    | 8           | 16 bits | Transaction identifier |

Operation values are defined in [const.p4](../p4/include/const.p4):

| Value | Constant              | Meaning                                          |
| ----- | --------------------- | ------------------------------------------------ |
| 1     | `NETLOCK_OP_ACQUIRED` | Acquire request (despite the constant's name)    |
| 2     | `NETLOCK_OP_RELEASE`  | Release request                                  |
| 3     | `NETLOCK_OP_GRANT`    | Grant reply                                      |
| 4     | `NETLOCK_OP_DRAIN`    | Defined but not handled by the local lock engine |

Mode values are `FREE = 1`, `SHARED = 2`, and `EXCLUSIVE = 3`. The current engine
uses single-owner semantics for all requests; it does not grant multiple shared
requests together.

The engine identifies an owner using the pair `(client_id, txn_id)`. A release
must match both values. Locally managed lock IDs currently range from `0` to
`1023`.

## Grant replies and checksums

A grant uses the same packet layout with `op = 3`. Ingress fills the recipient's
client ID, transaction ID, mode, MAC/IP address, UDP port, and destination QP
from engine metadata. On release with a waiter, the release packet becomes a
grant addressed to that waiter; the lock ID is retained.

Egress recalculates the ICRC over a pseudo-header and the IPv4-through-NetLock
fields, with invariant-field masks. The checksum stage updates the IPv4 header
checksum. Ingress sets the UDP checksum to zero when forwarding to the server
or sending a grant. Incoming checksums are not currently verified.

