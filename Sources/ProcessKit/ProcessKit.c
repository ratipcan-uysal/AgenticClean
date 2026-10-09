#include "ProcessKit.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <string.h>
#include <sys/resource.h>
#include <arpa/inet.h>
#include <stdlib.h>
int cleaner_pids(int32_t *buffer, int bytes) { return proc_listallpids(buffer, bytes); }
int cleaner_user_pids(uint32_t uid, int32_t *buffer, int bytes) { return proc_listpids(PROC_UID_ONLY, uid, buffer, bytes); }
int cleaner_read(int32_t pid, CleanerProcess *result) {
 struct proc_taskallinfo info;
 if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
 memset(result, 0, sizeof(*result));
 result->pid=pid; result->parent=info.pbsd.pbi_ppid; result->uid=info.pbsd.pbi_uid;
 result->start_seconds=info.pbsd.pbi_start_tvsec; result->start_microseconds=info.pbsd.pbi_start_tvusec;
 result->cpu_ns=info.ptinfo.pti_total_user+info.ptinfo.pti_total_system;
 result->resident=info.ptinfo.pti_resident_size;
 struct rusage_info_v2 usage;
 if(proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage)==0) {
  result->footprint=usage.ri_phys_footprint; result->footprint_valid=1;
  result->disk_read_bytes=usage.ri_diskio_bytesread;
  result->disk_write_bytes=usage.ri_diskio_byteswritten; result->disk_valid=1;
 } else {
  // Keep the original footprint path if extended accounting is unavailable.
  struct rusage_info_v0 fallback;
  if(proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&fallback)==0) {
   result->footprint=fallback.ri_phys_footprint; result->footprint_valid=1;
  }
 }
 if (proc_pidpath(pid,result->path,sizeof(result->path)) <= 0) return 0;
 // Reject PID reuse during the multi-call read, including reads made before SIGTERM.
 struct proc_bsdinfo verify;
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &verify, sizeof(verify)) != sizeof(verify) ||
     verify.pbi_start_tvsec != result->start_seconds || verify.pbi_start_tvusec != result->start_microseconds) return 0;
 return 1;
}
int cleaner_listeners(int32_t pid, uint64_t seconds, uint64_t micros,
                      CleanerListener *output, int capacity) {
 if (!output || capacity <= 0 || capacity > 128) return -3;
 int presence = cleaner_presence(pid, seconds, micros);
 if (presence != 1) return presence == -1 ? -1 : -2;
 const int max_fds = 4096;
 int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
 if (required < 0) return -1;
 if (required > max_fds * (int)sizeof(struct proc_fdinfo)) return -3;
 // One extra slot lets us detect truncation instead of presenting an incomplete inventory.
 int bytes = (max_fds + 1) * (int)sizeof(struct proc_fdinfo);
 struct proc_fdinfo *fds = calloc(1, bytes);
 if (!fds) return -1;
 int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
 if (got <= 0) { free(fds); return -1; }
 if (got >= bytes || got % sizeof(struct proc_fdinfo)) { free(fds); return -3; }
 int count = 0;
 for (int i = 0; i < got / (int)sizeof(struct proc_fdinfo); i++) {
  if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
  struct socket_fdinfo socket;
  if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) {
   free(fds); return -1;
  }
  if (socket.psi.soi_kind != SOCKINFO_TCP || socket.psi.soi_protocol != IPPROTO_TCP ||
      socket.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
  struct in_sockinfo *ip = &socket.psi.soi_proto.pri_tcp.tcpsi_ini;
  char host[46] = {0};
  if ((ip->insi_vflag & INI_IPV4) &&
      (ntohl(ip->insi_laddr.ina_46.i46a_addr4.s_addr) >> 24) == 127) {
   if (!inet_ntop(AF_INET, &ip->insi_laddr.ina_46.i46a_addr4, host, sizeof(host))) continue;
  } else if ((ip->insi_vflag & INI_IPV6) && IN6_IS_ADDR_LOOPBACK(&ip->insi_laddr.ina_6)) {
   if (!inet_ntop(AF_INET6, &ip->insi_laddr.ina_6, host, sizeof(host))) continue;
  } else continue;
  uint16_t port = ntohs((uint16_t)ip->insi_lport);
  if (!port) continue;
  if (count >= capacity) { free(fds); return -3; }
  output[count].port = port;
  output[count].generation = ip->insi_gencnt;
  strlcpy(output[count].host, host, sizeof(output[count].host));
  count++;
 }
 free(fds);
 presence = cleaner_presence(pid, seconds, micros);
 if (presence != 1) return presence == -1 ? -1 : -2;
 return count;
}
uint64_t cleaner_swap(void) {
 struct xsw_usage usage; size_t size=sizeof(usage);
 if(sysctlbyname("vm.swapusage", &usage, &size, NULL, 0) != 0) return UINT64_MAX;
 return usage.xsu_used;
}
int cleaner_cwd(int32_t pid, char *buffer, int size) {
 struct proc_vnodepathinfo info;
 if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
 strlcpy(buffer, info.pvi_cdir.vip_path, size);
 return 1;
}
#include <stdlib.h>
// Inspect argv only. Never return or retain environment variables or raw arguments.
int cleaner_is_maestro_mcp(int32_t pid) {
 int limit = 0; size_t limit_size = sizeof(limit);
 int limit_mib[] = {CTL_KERN, KERN_ARGMAX};
 if (sysctl(limit_mib, 2, &limit, &limit_size, NULL, 0) != 0 || limit <= 0 || limit > 2*1024*1024) return 0;
 char *buffer = malloc(limit);
 if (!buffer) return 0;
 size_t size = limit; int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
 if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0 || size < sizeof(int)) { free(buffer); return 0; }
 int argc = 0; memcpy(&argc, buffer, sizeof(argc));
 char *cursor = buffer + sizeof(argc), *end = buffer + size;
 char *zero = memchr(cursor, 0, end-cursor);
 if (!zero) { free(buffer); return 0; }
 cursor = zero + 1;
 while (cursor < end && *cursor == 0) cursor++;
 int maestro = 0, mcp = 0;
 for (int i=0; i<argc && cursor<end; i++) {
  zero = memchr(cursor, 0, end-cursor);
  if (!zero) break;
  if (strcmp(cursor, "maestro.cli.AppKt") == 0) maestro = 1;
  if (strcmp(cursor, "mcp") == 0) mcp = 1;
  cursor = zero + 1;
 }
 free(buffer);
 return maestro && mcp;
}
#include <mach/mach.h>
int cleaner_core_ticks(CleanerCoreTicks *output, int capacity) {
 if (!output || capacity <= 0 || capacity > 256) return -1;
 natural_t processors = 0;
 processor_info_array_t info = NULL;
 mach_msg_type_number_t count = 0;
 mach_port_t host = mach_host_self();
 kern_return_t status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count);
 mach_port_deallocate(mach_task_self(), host);
 if (status != KERN_SUCCESS) return -1;
 int valid = processors > 0 && processors <= capacity && count >= processors * CPU_STATE_MAX;
 if (valid) {
  for (natural_t i=0; i<processors; i++) {
   output[i].user = (uint32_t)info[i*CPU_STATE_MAX + CPU_STATE_USER];
   output[i].system = (uint32_t)info[i*CPU_STATE_MAX + CPU_STATE_SYSTEM];
   output[i].nice = (uint32_t)info[i*CPU_STATE_MAX + CPU_STATE_NICE];
   output[i].idle = (uint32_t)info[i*CPU_STATE_MAX + CPU_STATE_IDLE];
  }
 }
 vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
 return valid ? (int)processors : -1;
}
CleanerSystem cleaner_system(void) {
 CleanerSystem result = {0};
 result.pressure=-1;
 size_t pressure_size=sizeof(result.pressure);
 if (sysctlbyname("kern.memorystatus_vm_pressure_level", &result.pressure, &pressure_size, NULL, 0)!=0) result.pressure=-1;
 host_cpu_load_info_data_t cpu;
 mach_msg_type_number_t cpu_count = HOST_CPU_LOAD_INFO_COUNT;
 mach_port_t host = mach_host_self();
 if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count) == KERN_SUCCESS) {
  result.cpu_user=cpu.cpu_ticks[CPU_STATE_USER]; result.cpu_system=cpu.cpu_ticks[CPU_STATE_SYSTEM];
  result.cpu_idle=cpu.cpu_ticks[CPU_STATE_IDLE]; result.cpu_nice=cpu.cpu_ticks[CPU_STATE_NICE]; result.cpu_valid=1;
 }
 vm_statistics64_data_t vm;
 mach_msg_type_number_t vm_count=HOST_VM_INFO64_COUNT;
 vm_size_t page=0;
 if (host_page_size(host,&page)==KERN_SUCCESS && host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&vm_count)==KERN_SUCCESS) {
  result.wired=(uint64_t)vm.wire_count*page; result.compressed=(uint64_t)vm.compressor_page_count*page;
  result.active=(uint64_t)vm.active_count*page; result.inactive=(uint64_t)vm.inactive_count*page;
  result.page_size=page; result.swapins=vm.swapins; result.swapouts=vm.swapouts;
  result.compressions=vm.compressions; result.decompressions=vm.decompressions;
  result.free_bytes=(uint64_t)vm.free_count*page; result.memory_valid=1;
 }
 mach_port_deallocate(mach_task_self(),host);
 return result;
}
#include <errno.h>
#include <signal.h>
int cleaner_presence(int32_t pid, uint64_t seconds, uint64_t micros) {
 if(pid <= 0) return -1;
 struct proc_bsdinfo info;
 if(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
  if(info.pbi_status == 5) return 0; // SZOMB: terminated, waiting to be reaped.
  if(seconds == 0) return 1;
  return info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == micros ? 1 : 2;
 }
 if(kill(pid,0)==-1 && errno==ESRCH) return 0;
 return -1;
}
