from enum import IntEnum


# Shared by the client, server, and packet builder.
NUM_LOCKS = 100  # Valid lock IDs: 0 through NUM_LOCKS - 1.
RDMA_UDP_PORT = 4791
CLIENT_QPN = 1
SERVER_QPN = 1
Q_KEY = 0x11111111


class Scenario(IntEnum):
    CIRCULAR = 1
    RANDOM = 2
