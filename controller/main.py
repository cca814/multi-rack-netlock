#!/usr/bin/env python3

import argparse
import ipaddress
import json
from pathlib import Path
import re
import sys


INGRESS = "NetLockIngress"


def _fields(value, required, optional=()):
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    missing = set(required) - value.keys()
    unknown = value.keys() - set(required) - set(optional)
    if missing or unknown:
        raise ValueError(f"missing fields: {sorted(missing)}; unknown fields: {sorted(unknown)}")


def _integer(value, name, maximum):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(f"{name} must be an integer between 0 and {maximum}")


def _mac(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", value):
        raise ValueError(f"invalid MAC address: {value!r}")


def _ipv4(value):
    if not isinstance(value, str):
        raise ValueError("IP addresses must be IPv4 strings")
    ipaddress.IPv4Address(value)


def validate_config(config):
    _fields(config, {"switch_mac", "routes"}, {"switch_lock_ids"})
    _mac(config["switch_mac"])
    routes = config["routes"]
    if not isinstance(routes, list) or not 1 <= len(routes) <= 1024:
        raise ValueError("routes must contain between 1 and 1024 entries")
    seen_ips = set()
    for route in routes:
        _fields(route, {"ip", "mac", "port"})
        _ipv4(route["ip"])
        _mac(route["mac"])
        # v1model ports are 9 bits; BMv2's default drop port is 511.
        _integer(route["port"], "route.port", 510)
        if route["ip"] in seen_ips:
            raise ValueError(f"duplicate route IP: {route['ip']}")
        seen_ips.add(route["ip"])

    lock_ids = config.get("switch_lock_ids", [])
    if not isinstance(lock_ids, list):
        raise ValueError("switch_lock_ids must be a list")
    for lock_id in lock_ids:
        _integer(lock_id, "switch lock ID", 1023)
    if len(set(lock_ids)) != len(lock_ids):
        raise ValueError("switch_lock_ids contains duplicates")


def build_rules(config):
    validate_config(config)
    rules = [
        {"table": f"{INGRESS}.node_config", "action": "NoAction", "default": True},
        {"table": f"{INGRESS}.lock_id_to_action",
         "action": f"{INGRESS}.route_packet", "default": True},
    ]
    for route in config["routes"]:
        rules.append({
            "table": f"{INGRESS}.ipv4_forward",
            "action": f"{INGRESS}.forward",
            "match": {"headers.ipv4.dst_addr": route["ip"]},
            "params": {"next_hop_mac": route["mac"], "port": str(route["port"])},
        })
    for lock_id in config.get("switch_lock_ids", []):
        rules.append({
            "table": f"{INGRESS}.lock_id_to_action",
            "action": f"{INGRESS}.set_action",
            "match": {"headers.netlock.lock_id": str(lock_id)},
        })
    rules.append({
        "table": f"{INGRESS}.node_config",
        "action": f"{INGRESS}.set_node_config",
        "default": True,
        "params": {"switch_mac_addr": config["switch_mac"]},
    })
    return rules


def install_rules(sh, rules):
    entries = []
    for rule in rules:
        entry = sh.TableEntry(rule["table"])(
            action=rule["action"], is_default=rule.get("default", False),
        )
        for field, value in rule.get("match", {}).items():
            entry.match[field] = value
        for param, value in rule.get("params", {}).items():
            entry.action[param] = value
        entries.append(entry)

    # All names / field values have been checked against the loaded P4Info.
    entries[0].modify()  # NoAction: drop packets while rebuilding the tables.
    for table in ("ipv4_forward", "lock_id_to_action"):
        for old in list(sh.TableEntry(f"{INGRESS}.{table}").read()):
            if not old.is_default:
                old.delete()
    for entry in entries[1:]:
        if entry.is_default:
            entry.modify()
        else:
            entry.insert()


def apply_rules(rules, grpc_addr, device_id, election_id, p4info=None, bmv2_json=None):
    try:
        import p4runtime_sh.shell as sh
    except ImportError as exc:
        raise RuntimeError("Install dependencies: python3 -m pip install -r controller/requirements.txt") from exc
    pipeline = sh.FwdPipeConfig(str(p4info), str(bmv2_json)) if p4info else None
    sh.setup(device_id=device_id, grpc_addr=grpc_addr, election_id=election_id,
             config=pipeline, verbose=False)
    try:
        install_rules(sh, rules)
    except Exception as exc:
        raise RuntimeError(f"P4Runtime rule installation failed: {exc}") from exc
    finally:
        sh.teardown()


def parse_election_id(value):
    try:
        parts = tuple(int(part) for part in value.split(","))
        if len(parts) != 2 or parts == (0, 0):
            raise ValueError
        for part in parts:
            _integer(part, "election ID component", (1 << 64) - 1)
        return parts
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected nonzero HIGH,LOW with unsigned 64-bit values") from exc


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Install static NetLock rules on BMv2 simple_switch_grpc using P4Runtime.",
    )
    parser.add_argument("--config", required=True, type=Path, help="topology JSON file")
    parser.add_argument("--grpc-addr", default="127.0.0.1:9559")
    parser.add_argument("--device-id", type=int, default=0)
    parser.add_argument("--election-id", type=parse_election_id, default=(0, 1), metavar="HIGH,LOW")
    parser.add_argument("--p4info", type=Path, default=Path("build/netlock.p4info.txt"))
    parser.add_argument("--bmv2-json", type=Path, default=Path("build/netlock.json"))
    parser.add_argument("--skip-pipeline", action="store_true",
                        help="use the pipeline already installed on the switch")
    parser.add_argument("--dry-run", action="store_true", help="print rules without connecting")
    args = parser.parse_args(argv)
    try:
        _integer(args.device_id, "device ID", (1 << 64) - 1)
        config = json.loads(args.config.read_text())
        rules = build_rules(config)
        if args.dry_run:
            print(json.dumps({
                "grpc_addr": args.grpc_addr, "device_id": args.device_id,
                "load_pipeline": not args.skip_pipeline,
                "clear_tables": [f"{INGRESS}.ipv4_forward", f"{INGRESS}.lock_id_to_action"],
                "rules": rules,
            }, indent=2))
        else:
            if not args.skip_pipeline:
                for artifact in (args.p4info, args.bmv2_json):
                    if not artifact.is_file():
                        raise ValueError(f"Missing pipeline artifact: {artifact}; compile p4/main.p4 first")
            apply_rules(rules, args.grpc_addr, args.device_id, args.election_id,
                        None if args.skip_pipeline else args.p4info,
                        None if args.skip_pipeline else args.bmv2_json)
            print(f"Installed {len(config['routes'])} IPv4 route(s); forwarding enabled.")
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Controller error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
