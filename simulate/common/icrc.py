import argparse
import struct
import zlib


def icrc_input(ip_packet: bytes) -> bytes:
    if len(ip_packet) < 64 or ip_packet[0] != 0x45:
        raise ValueError("expected IPv4 without options and a complete NetLock packet")
    total = int.from_bytes(ip_packet[2:4], "big")
    if total != 64 or len(ip_packet) < total:
        raise ValueError("expected 64-byte IPv4 NetLock datagram")
    if ip_packet[9] != 17 or int.from_bytes(ip_packet[6:8], "big") & 0x3fff:
        raise ValueError("expected unfragmented UDP")
    if int.from_bytes(ip_packet[24:26], "big") != 44:
        raise ValueError("expected UDP length 44")
    if ip_packet[28] != 0x64 or ip_packet[29] & 0x3f != 0x20:
        raise ValueError("expected UD_SEND_ONLY, version 0 and two padding bytes")
    data = bytearray(ip_packet[:total - 4])
    data[1] = data[8] = 0xff  # TOS and TTL
    data[10:12] = b"\xff\xff"  # IPv4 checksum
    data[26:28] = b"\xff\xff"  # UDP checksum
    data[32] = 0xff  # BTH reserved/FECN/BECN byte; retain destination QP
    return b"\xff" * 8 + data


def compute_icrc(ip_packet: bytes) -> bytes:
    return struct.pack("<I", zlib.crc32(icrc_input(ip_packet)))


def valid_icrc(ip_packet: bytes) -> bool:
    expected = compute_icrc(ip_packet)
    total = int.from_bytes(ip_packet[2:4], "big")
    return ip_packet[total - 4:total] == expected


def main():
    from scapy.all import PcapReader, IP, UDP
    from simulate.common.config import RDMA_UDP_PORT

    parser = argparse.ArgumentParser(description="Validate RoCEv2 NetLock ICRC in a packet capture.")
    parser.add_argument("pcap")
    args = parser.parse_args()
    checked = bad = 0
    with PcapReader(args.pcap) as packets:
        for index, packet in enumerate(packets, 1):
            if IP not in packet or UDP not in packet or packet[UDP].dport != RDMA_UDP_PORT:
                continue
            checked += 1
            try:
                good = valid_icrc(bytes(packet[IP]))
                reason = "ICRC mismatch"
            except ValueError as exc:
                good, reason = False, str(exc)
            if not good:
                bad += 1
                print(f"packet {index}: {reason}")
    print(f"Checked {checked} RoCE packets; {bad} invalid")
    return 1 if bad or not checked else 0


if __name__ == "__main__":
    raise SystemExit(main())
