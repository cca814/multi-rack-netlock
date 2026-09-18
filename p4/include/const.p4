#ifndef _NETLOCK_CONST_P4_
#define _NETLOCK_CONST_P4_

const bit<16> ETHERTYPE_IPV4 = 0x0800;
const bit<8> IP_PROTO_UDP = 17;
const bit<16> UDP_PORT_ROCEV2 = 4791;

// NetLock OP code
const bit<8> NETLOCK_OP_ACQUIRED = 1;
const bit<8> NETLOCK_OP_RELEASE = 2;
const bit<8> NETLOCK_OP_GRANT = 3;
const bit<8> NETLOCK_OP_DRAIN = 4;

// NetLock Mode
const bit<8> NETLOCK_MODE_FREE = 1;
const bit<8> NETLOCK_MODE_SHARED = 2;
const bit<8> NETLOCK_MODE_EXCLUSIVE = 3;

// NetLock state
const bit<8> NETLOCK_STATE_HOT = 1;
const bit<8> NETLOCK_STATE_COLD = 2;
const bit<8> NETLOCK_STATE_MIG_TO_SWITCH = 3;
const bit<8> NETLOCK_STATE_MIG_TO_SERVER = 4;

// Lock engine storage limits. lock_id is a direct register index.
const bit<32> NETLOCK_MAX_LOCKS = 1024;
const bit<32> NETLOCK_QUEUE_DEPTH = 16;

// Lock engine results, consumed by ingress when deciding what to emit.
const bit<8> NETLOCK_ENGINE_ACTION_NONE = 0;
const bit<8> NETLOCK_ENGINE_ACTION_GRANT = 1;
const bit<8> NETLOCK_ENGINE_ACTION_ENQUEUE = 2;
const bit<8> NETLOCK_ENGINE_ACTION_RELEASE = 3;
const bit<8> NETLOCK_ENGINE_ACTION_QUEUE_FULL = 4;
const bit<8> NETLOCK_ENGINE_ACTION_INVALID_LOCK = 5;
const bit<8> NETLOCK_ENGINE_ACTION_INVALID_RELEASE = 6;

#endif
