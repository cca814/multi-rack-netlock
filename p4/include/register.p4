// Included inside NetLockEngine: each engine instance owns its lock storage.
// Registers must start at zero before traffic is admitted.
register<bit<1>>(NETLOCK_MAX_LOCKS) lock_owned;
register<bit<32>>(NETLOCK_MAX_LOCKS) lock_owner;
register<bit<32>>(NETLOCK_MAX_LOCKS) lock_queue_head;
register<bit<32>>(NETLOCK_MAX_LOCKS) lock_queue_tail;
register<bit<32>>(NETLOCK_MAX_LOCKS) lock_queue_count;

// Packed lock_client_t: port, MAC, IPv4, UDP port, QP, client, txn, mode.
register<bit<169>>(NETLOCK_MAX_LOCKS * NETLOCK_QUEUE_DEPTH) lock_waiters;
