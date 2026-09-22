# Static P4Runtime controller

`main.py` is a one-shot startup controller for **BMv2 `simple_switch_grpc`**.
It opens a P4Runtime session, loads the compiled P4 pipeline, installs rules
from a JSON topology, and exits. The switch continues forwarding after it exits.
It uses the Python API of [p4runtime-shell](https://github.com/p4lang/p4runtime-shell#using-p4runtime-shell-in-scripts)
for arbitration, P4Info name resolution, and table writes.

```text
client -- port 2 [ P4 switch ] port 1 -- server
       ACQUIRE / RELEASE -->
                         <-- GRANT
```

For the complete local topology, use the [Makefile workflow](../README.md#run-client-p4-switch-and-server-on-ubuntu):
`make p4-setup`, then `make p4-switch` in one terminal, `make p4-rules` followed
by `make p4-server` in another, and `make p4-client` in a third. Stop the
processes before running `make p4-down`. The commands below also support
manual operation on an existing topology.

## Files and configuration

- `main.py`: config validation, rule construction, and P4Runtime installation.
- `config.example.json`: example endpoint addresses and switch port mapping.
- `requirements.txt`: controller dependency.

Run commands below from the repository root. Copy
`controller/config.example.json` to `controller/config.json` and edit it for
your topology.

| Field | Meaning |
| --- | --- |
| `switch_mac` | Source MAC written by the switch in forwarded packets |
| `routes[].ip` | Exact destination IPv4 address |
| `routes[].mac` | Next-hop destination MAC |
| `routes[].port` | BMv2 output port |
| `switch_lock_ids` | Optional list of locks handled by the switch; empty routes all requests to their destination |

Ports are the numbers passed to `simple_switch_grpc -i`, not Linux interface
indexes. There are no server/client roles in the routing configuration, and
multiple destination IPs may share the same next-hop MAC and port. Add a route
for every destination, including recipients of switch-generated grants.
The controller assumes BMv2's default drop port, 511, and rejects it as an
output port. Switch-managed lock IDs must be in the range 0–1023.

The example routes `10.200.0.2` to port 1 and `10.200.0.1` to port 2. Routing
preserves source/destination IPs, UDP ports, and QPNs; packets must already
carry the intended endpoint IP and destination QPN. Queue keys must also match
between endpoints. QPN is not a routing key in this version; the exact IP
lookup selects a next-hop MAC and port.

If you used the earlier controller, replace its `server` and `clients` sections
with the single `routes` list in the updated example. Remove `server.qpn` from
the controller configuration and set the intended QPN in the sender instead.

## Install dependencies and compile

On a Linux machine with `p4c-bm2-ss` and `simple_switch_grpc` installed:

```bash
python3 -m venv .venv-controller
.venv-controller/bin/python -m pip install -r controller/requirements.txt

mkdir -p build
p4c-bm2-ss --std p4-16 --p4runtime-files build/netlock.p4info.txt \
  -o build/netlock.json p4/main.p4
```

Recompile and reload the pipeline after this refactor: the table is now
`ipv4_forward`, and `set_node_config` takes only the switch MAC. Do not use
`--skip-pipeline` with the old pipeline.

## Start the switch

```bash
# Replace sw-server and sw-client with your actual switch-side interfaces.
sudo simple_switch_grpc --device-id 0 --no-p4 \
  -i 1@sw-server -i 2@sw-client \
  -- --grpc-server-addr 127.0.0.1:9559
```

Keep the switch running and use another terminal for the controller.
`--no-p4` starts the switch without a pipeline; the controller installs both
P4Info and BMv2 JSON through P4Runtime. This follows BMv2's
[startup procedure](https://github.com/p4lang/behavioral-model/blob/main/targets/simple_switch_grpc/README.md#running-simple_switch_grpc).

`make p4-up` creates the `sw-client` and `sw-server` interfaces shown above,
with a veth pair to each endpoint namespace. `make p4-setup` also installs
Python dependencies and compiles the pipeline. `make sim-up` creates the
separate direct client/server topology; remove it with `make sim-down` before
switching to the P4 topology.

## Preview and install rules

```bash
cp controller/config.example.json controller/config.json
# Edit controller/config.json to match your switch ports and endpoint addresses.
.venv-controller/bin/python controller/main.py \
  --config controller/config.json --dry-run
.venv-controller/bin/python controller/main.py \
  --config controller/config.json --grpc-addr 127.0.0.1:9559 --device-id 0
```

`--dry-run` prints a JSON plan without dependencies, compiled files, or a running
switch. The default pipeline files are `build/netlock.p4info.txt` and
`build/netlock.json`; override them with `--p4info` and `--bmv2-json`.
Use `--skip-pipeline` to use the pipeline already loaded on the switch and only
replace rules. The default election ID is `0,1`; use `--election-id HIGH,LOW`
when needed. The controller must be the primary P4Runtime client to write.
The default connection uses plaintext gRPC, suitable for a local lab setup.

The controller programs:

1. `node_config`: switch source MAC and forwarding enable.
2. `ipv4_forward`: destination IP → next-hop MAC and output port, for all endpoints.
3. `lock_id_to_action`: optional switch-managed locks; default uses normal routing.

Rule installation disables ingress with `node_config`, deletes existing route
and lock-placement entries, installs the configured entries, then enables
ingress last. Reapplying replaces old rules instead of adding duplicates.
A failed table write stops installation before the final enable write.

**Run this at startup, before sending traffic.** Loading the pipeline replaces
switch state. Even with `--skip-pipeline`, applying interrupts forwarding and
replaces these tables. This controller does not migrate lock ownership. To
change lock placement after a test, finish all outstanding locks and start a
fresh switch and server before applying the new configuration.

## Packet behavior and inspection

Every routable packet uses `ipv4_forward`, regardless of its source IP or
ingress port. The next hop is selected only by destination IP. The switch
writes its source MAC and the configured next-hop destination MAC.

Only ACQUIRE and RELEASE packets consult lock placement. If the lock is local,
the engine consumes the request and may prepare a GRANT for the owner or a
queued waiter. That generated GRANT uses the same IP routing table. Requests
consumed without a grant are dropped rather than forwarded to another owner.
Received GRANT packets bypass the engine even when their lock ID is local.

Transit packets with TTL ≤ 1 are dropped; other transit packets lose one hop.
Switch-generated grants start with TTL 64. Unknown destination IPs are dropped
for both transit packets and generated grants. The existing checksum stages
update IPv4 and ICRC after forwarding, and the UDP checksum is set to zero.

Use the simulation's fixed NetLock/RoCE packet layout on UDP port 4791. ARP,
ICMP/ping, and arbitrary IP traffic are not forwarded by this P4 program.
Scapy's `sendp` builds Ethernet headers explicitly, so set endpoint MAC/IP and
interface values for your topology. Run `server.start()` before `client.start()`
once the rules are installed.

After the controller exits, inspect entries through the P4Runtime shell:

```bash
.venv-controller/bin/python -m p4runtime_sh \
  --grpc-addr 127.0.0.1:9559 --device-id 0 --election-id 0,1
```

```python
print(next(table_entry["NetLockIngress.node_config"](is_default=True).read()))
table_entry["NetLockIngress.ipv4_forward"].read(lambda entry: print(entry))
table_entry["NetLockIngress.lock_id_to_action"].read(lambda entry: print(entry))
```

Run controller checks without a switch:

```bash
.venv-controller/bin/python -m unittest discover -s tests -v
```
