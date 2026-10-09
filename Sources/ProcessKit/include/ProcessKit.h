#include <stdint.h>
typedef struct {
 int32_t pid, parent; uint32_t uid;
 uint64_t start_seconds, start_microseconds, cpu_ns, resident, footprint;
 int footprint_valid;
 uint64_t disk_read_bytes, disk_write_bytes;
 int disk_valid;
 char path[4096];
} CleanerProcess;
int cleaner_pids(int32_t *buffer, int bytes);
// Returns byte count, unlike cleaner_pids which returns a PID count.
int cleaner_user_pids(uint32_t uid, int32_t *buffer, int bytes);
int cleaner_read(int32_t pid, CleanerProcess *result);
uint64_t cleaner_swap(void);
int cleaner_cwd(int32_t pid, char *buffer, int size);
int cleaner_is_maestro_mcp(int32_t pid);
typedef struct {
 uint64_t cpu_user, cpu_system, cpu_idle, cpu_nice;
 uint64_t wired, compressed, active, inactive, free_bytes;
 uint64_t swapins, swapouts, compressions, decompressions, page_size;
 int pressure;
 int cpu_valid, memory_valid;
} CleanerSystem;
CleanerSystem cleaner_system(void);
// 0 absent/zombie; 1 same identity (or existence-only); 2 replaced; -1 unreadable.
int cleaner_presence(int32_t pid, uint64_t seconds, uint64_t micros);
typedef struct {
 uint16_t port;
 uint64_t generation;
 char host[46];
} CleanerListener;
// Loopback TCP listeners only. -1 unreadable, -2 identity changed, -3 bounds exceeded.
int cleaner_listeners(int32_t pid, uint64_t seconds, uint64_t micros,
                      CleanerListener *output, int capacity);
typedef struct { uint32_t user, system, nice, idle; } CleanerCoreTicks;
// Returns processor count, or -1 for unavailable/bounds exceeded.
int cleaner_core_ticks(CleanerCoreTicks *output, int capacity);
