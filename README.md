# multi-rack-netlock

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
