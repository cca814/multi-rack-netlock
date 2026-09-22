# multi-rack-netlock

## P4 switch controller

For a `client ↔ BMv2 simple_switch_grpc ↔ server` topology, use the small P4Runtime
[controller](controller/README.md). It installs destination-IP routes for all
endpoints and optionally selects locks for the switch's lock engine. Requests
and replies share one routing table; each route selects a next-hop MAC and port.
Preview the rules without a running switch:

```bash
python3 controller/main.py --config controller/config.example.json --dry-run
```

## Run client, P4 switch, and server on Ubuntu

Install `p4c-bm2-ss` and BMv2 `simple_switch_grpc` first. Run these commands from
the repository root. `sim-deps` installs the basic Ubuntu tools; it does not
install the P4 compiler or BMv2.

```bash
make sim-deps
make p4-setup
```

`p4-setup` installs the client/server and controller Python dependencies,
compiles the P4 program, and creates two namespaces with separate links to
the switch. If the old simulation is running, stop and exit its shells and
run `make sim-down` before setup. Setup refuses to overwrite existing
namespaces or interfaces.

```text
netlock-client:nl-client -- sw-client [port 2 | BMv2 | port 1] sw-server -- nl-server:netlock-server
```

In terminal 1, start the switch and leave it running:

```bash
make p4-switch
```

In terminal 2, load the pipeline and rules, then start the server:

```bash
make p4-rules
make p4-server
```

After the server starts, run the client in terminal 3:

```bash
make p4-client
```

The client performs 10 acquire/release cycles with a 0.5-second hold and a
5-second reply timeout. Success prints `Completed 10 lock cycles`. Both endpoint
logs also go to `logs/`. Override the workload as needed:

```bash
make p4-client CLIENT_CYCLES=100 CLIENT_HOLD_TIME=0.1 CLIENT_REPLY_TIMEOUT=10
```

The default `controller/config.example.json` routes all locks to the server.
Use `make p4-rules P4_CONFIG=controller/config.json` for your own routes and lock
placement. The supplied network uses port 1 for `sw-server` and port 2 for
`sw-client`; its endpoint addresses match the example config.

Stop the client, server, and switch with Ctrl+C, then remove the network:

```bash
make p4-down
```

Cleanup refuses while processes remain in either endpoint namespace. It removes
the namespaces and their veth pairs, including `sw-client` and `sw-server` in the
P4 topology. Python environments and build outputs are kept. Recreate only the
network with `make p4-up`; recompile after P4 edits with `make p4-build` and reload
it using `make p4-rules` before starting a new workload.

For interactive endpoint control, use `make p4-client-shell` and
`make p4-server-shell`; these open Python shells without starting traffic.
`P4_GRPC_ADDR` (default `127.0.0.1:9559`) and `P4_DEVICE_ID` (default `0`) must
match between `p4-switch` and `p4-rules`. Other overrides include `P4C`,
`P4_SWITCH`, `P4_BUILD_DIR`, `P4_ELECTION_ID`, and `CONTROLLER_VENV`.
`make p4-rules-dry-run` previews the configured rules without a switch.

## Simulation setup on Ubuntu

Shared simulation settings live in `simulate/common/config.py`: `NUM_LOCKS`,
`RDMA_UDP_PORT`, `CLIENT_QPN`, `SERVER_QPN`, and `Q_KEY`. By default there are
100 locks with IDs 0–99; the client selects from this range and the server
ignores IDs outside it. Restart both Python shells after changing settings.
Client-only cycle count and `HOLD_TIME` remain in `simulate/client/main.py`.

One machine hosts two network namespaces connected directly by a veth pair.
No P4 compiler, switch, or RDMA NIC is required.

```bash
make sim-deps       # Install Ubuntu prerequisites once
make sim-setup      # Install Scapy in .venv and create the network
```

| Namespace | Interface | IP address | MAC address |
| --- | --- | --- | --- |
| netlock-client | nl-client | 10.200.0.1/24 | 02:00:00:00:00:01 |
| netlock-server | nl-server | 10.200.0.2/24 | 02:00:00:00:00:02 |

Open each endpoint in a separate terminal:

```bash
make sim-client-shell
make sim-server-shell
```

The client shell provides a configured `client` object. The server shell
provides a configured `server` (`Server`) object. These are interactive Python
shells; setup does not start traffic. Both endpoints use queue pair 1; the configured
client uses queue key `0x11111111` and client ID 101.

First start the server in the server shell:

```python
server.start()  # Ctrl+C stops serving
```

Then start the client from its shell:

```python
import simulate.client.main as client_module
client_module.NUM_OF_LOCK_TO_ACQUIRED = 10  # Number of acquire/release cycles
client_module.HOLD_TIME = 0.5     # Seconds to hold each granted lock
grants = client.start(reply_timeout=5.0)
```

Each cycle chooses a random lock, waits for a matching GRANT, holds the lock,
then sends RELEASE with the same client, lock, and transaction IDs before
starting the next cycle. A grant timeout raises `TimeoutError` and stops the
run. A new transaction ID is used for each cycle (16-bit, wrapping at 65536).

The server grants free locks immediately and queues contending requests in FIFO
order. Only the current owner can release a lock; release grants it to the first
waiter or makes it free. Duplicate queued requests are ignored. Both SHARED and
EXCLUSIVE modes currently use single-owner semantics. State is kept in memory;
there is no automatic expiry or cancellation for disconnected clients, so set
the client's reply timeout long enough for expected queue waits.

Exit both shells before removing the network:

```bash
make sim-down
```

`sim-down` removes only the two named namespaces and their virtual link;
it keeps the Python environment. Use `make sim-up` to recreate the network.
The namespace names are reserved for this simulation; setup refuses to
overwrite existing namespaces. Host interfaces and routes are not modified.
Use `make help` to list targets. `PYTHON`, `VENV`, and `SUDO` can be overridden
as Make variables (for example, `make sim-up SUDO=` when already root).

## Logging

Client events automatically go to `logs/client.log`; server events go to
`logs/server.log`, relative to the working directory. Both also appear on stdout
with local timestamps including milliseconds, client IDs, lock IDs, and transaction
IDs. Client logs cover acquire sends, grant receipts, hold duration, and release
sends. Server logs cover acquire receipts, immediate grants or queue placement,
grant sends, and releases. Existing files are appended to.

Use the common utility to write the same timestamped messages to stdout and
a chosen file. Parent directories are created automatically; existing files
are appended to.

```python
from simulate.common.utils import get_logger

logger = get_logger("logs/server.log")
logger.info("Server started")
logger.info("Granted lock %s to client %s", lock_id, client_id)
logger.warning("Ignoring release from a non-owner")
```

The default level is `logging.INFO`. Pass `level=logging.DEBUG` to include
debug messages. Repeated calls for the same file reuse the logger.
