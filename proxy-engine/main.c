/* Local HTTP/SOCKS/forward proxy over user-space PPTP, PPP, MPPE and lwIP.
 * PPTP carriage: pptpclient 1.10.0 (GPL-2.0-or-later)
 * PPP/MPPE/TCP/IP: lwIP 2.2.1 (BSD-3-Clause)
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#include "lwip/dns.h"
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "netif/ppp/ppp.h"
#include "netif/ppp/pppos.h"

#define MAX_CONNECTIONS 128
#define MAX_LISTENERS 34
#define MAX_HEADER 8192
#define BUFFER_SIZE 65536
#define MAX_CONTROL_REQUEST 16384

enum listener_kind { HTTP_PROXY, SOCKS_PROXY, FORWARD };
enum connection_phase { PROXY_HEADER, SOCKS_GREETING, SOCKS_REQUEST, RESOLVING, CONNECTING, STREAMING, CONNECTION_CLOSED };

struct listener {
  int fd;
  enum listener_kind kind;
  int local_port;
  int remote_port;
  char remote_host[256];
};

struct connection {
  int fd;
  enum listener_kind kind;
  enum connection_phase phase;
  struct tcp_pcb *tcp;
  bool resolving;
  bool remote_closed;
  bool http_connect;
  char host[256];
  int port;
  uint8_t header[MAX_HEADER];
  size_t header_len;
  uint8_t to_remote[BUFFER_SIZE];
  size_t remote_len;
  uint8_t to_local[BUFFER_SIZE];
  size_t local_len;
};

static struct connection connections[MAX_CONNECTIONS];
static struct listener listeners[MAX_LISTENERS];
static size_t listener_count;
static struct netif ppp_netif;
static ppp_pcb *ppp;
static int pty_fd = -1;
static int control_fd = -1;
static const char *control_socket_path;
static pid_t pptp_pid = -1;
static bool link_up;
static volatile sig_atomic_t stop_requested;
static char vpn_password[512];
static uint64_t sent_bytes;
static uint64_t received_bytes;
static uint64_t connected_since_ms;

static void log_line(const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  va_end(args);
  fputc('\n', stderr);
  fflush(stderr);
}

static void on_signal(int sig) { (void)sig; stop_requested = 1; }

static void erase_secret(void *memory, size_t length) {
  volatile unsigned char *bytes = memory;
  while (length--) *bytes++ = 0;
}

u32_t sys_now(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (u32_t)(now.tv_sec * 1000ULL + now.tv_nsec / 1000000ULL);
}

static uint64_t monotonic_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

unsigned int lwip_port_rand(void) { return arc4random(); }

u32_t sys_jiffies(void) { return sys_now() / 10; }
sys_prot_t sys_arch_protect(void) { return 0; }
void sys_arch_unprotect(sys_prot_t token) { (void)token; }

static int nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int listen_loopback(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 32) || nonblocking(fd)) {
    close(fd);
    return -1;
  }
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

static int listen_control(const char *path) {
  if (!path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return -1;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  strcpy(addr.sun_path, path);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || chmod(path, 0666) || listen(fd, 2) || nonblocking(fd)) {
    close(fd);
    return -1;
  }
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

static void cleanup_control_socket(void) {
  if (control_fd >= 0) { close(control_fd); control_fd = -1; }
  if (control_socket_path) { unlink(control_socket_path); control_socket_path = NULL; }
}

static void close_connection(struct connection *c) {
  if (c->fd >= 0) close(c->fd);
  c->fd = -1;
  if (c->tcp) {
    tcp_arg(c->tcp, NULL);
    tcp_recv(c->tcp, NULL);
    tcp_sent(c->tcp, NULL);
    tcp_err(c->tcp, NULL);
    tcp_poll(c->tcp, NULL, 0);
    tcp_abort(c->tcp);
    c->tcp = NULL;
  }
  c->phase = CONNECTION_CLOSED;
  c->remote_len = c->local_len = c->header_len = 0;
}

static bool append_bytes(uint8_t *buffer, size_t *length, size_t capacity, const void *src, size_t count) {
  if (count > capacity - *length) return false;
  memcpy(buffer + *length, src, count);
  *length += count;
  return true;
}

static bool local_reply(struct connection *c, const void *data, size_t length) {
  return append_bytes(c->to_local, &c->local_len, sizeof(c->to_local), data, length);
}

static void flush_remote(struct connection *c) {
  if (!c->tcp || c->phase != STREAMING || !c->remote_len) return;
  u16_t space = tcp_sndbuf(c->tcp);
  size_t count = c->remote_len < space ? c->remote_len : space;
  if (count > TCP_MSS) count = TCP_MSS;
  if (!count) return;
  if (tcp_write(c->tcp, c->to_remote, (u16_t)count, TCP_WRITE_FLAG_COPY) != ERR_OK) return;
  memmove(c->to_remote, c->to_remote + count, c->remote_len - count);
  c->remote_len -= count;
  tcp_output(c->tcp);
}

static err_t on_tcp_sent(void *arg, struct tcp_pcb *tcp, u16_t length) {
  (void)tcp;
  sent_bytes += length;
  flush_remote((struct connection *)arg);
  return ERR_OK;
}

static err_t on_tcp_poll(void *arg, struct tcp_pcb *tcp) {
  (void)tcp;
  flush_remote((struct connection *)arg);
  return ERR_OK;
}

static void on_tcp_error(void *arg, err_t err) {
  struct connection *c = arg;
  c->tcp = NULL;
  log_line("원격 TCP 오류 %s:%d: %d", c->host, c->port, err);
  close_connection(c);
}

static err_t on_tcp_receive(void *arg, struct tcp_pcb *tcp, struct pbuf *p, err_t err) {
  struct connection *c = arg;
  if (err != ERR_OK) return err;
  if (!p) {
    c->remote_closed = true;
    tcp_arg(tcp, NULL);
    tcp_recv(tcp, NULL);
    tcp_sent(tcp, NULL);
    tcp_err(tcp, NULL);
    tcp_poll(tcp, NULL, 0);
    if (tcp_close(tcp) != ERR_OK) {
      tcp_abort(tcp);
      c->tcp = NULL;
      if (!c->local_len) close_connection(c);
      return ERR_ABRT;
    }
    c->tcp = NULL;
    if (!c->local_len) close_connection(c);
    return ERR_OK;
  }
  if (p->tot_len > sizeof(c->to_local) - c->local_len) return ERR_MEM;
  pbuf_copy_partial(p, c->to_local + c->local_len, p->tot_len, 0);
  c->local_len += p->tot_len;
  received_bytes += p->tot_len;
  tcp_recved(tcp, p->tot_len);
  pbuf_free(p);
  return ERR_OK;
}

static err_t on_tcp_connected(void *arg, struct tcp_pcb *tcp, err_t err) {
  struct connection *c = arg;
  if (err != ERR_OK) { close_connection(c); return ERR_ABRT; }
  c->phase = STREAMING;
  if (c->kind == HTTP_PROXY && c->http_connect) {
    static const char ok[] = "HTTP/1.1 200 Connection Established\r\n\r\n";
    if (!local_reply(c, ok, sizeof(ok)-1)) { close_connection(c); return ERR_ABRT; }
  } else if (c->kind == SOCKS_PROXY) {
    static const uint8_t ok[] = {5,0,0,1,0,0,0,0,0,0};
    if (!local_reply(c, ok, sizeof(ok))) { close_connection(c); return ERR_ABRT; }
  }
  log_line("원격 연결 %s:%d", c->host, c->port);
  flush_remote(c);
  return ERR_OK;
}

static void connect_ip(struct connection *c, const ip_addr_t *address) {
  c->resolving = false;
  if (c->phase == CONNECTION_CLOSED || c->fd < 0) return;
  c->tcp = tcp_new_ip_type(IPADDR_TYPE_V4);
  if (!c->tcp) { close_connection(c); return; }
  tcp_arg(c->tcp, c);
  tcp_recv(c->tcp, on_tcp_receive);
  tcp_sent(c->tcp, on_tcp_sent);
  tcp_err(c->tcp, on_tcp_error);
  tcp_poll(c->tcp, on_tcp_poll, 2);
  c->phase = CONNECTING;
  if (tcp_connect(c->tcp, address, (u16_t)c->port, on_tcp_connected) != ERR_OK) close_connection(c);
}

static void dns_done(const char *name, const ip_addr_t *address, void *arg) {
  struct connection *c = arg;
  if (!address) {
    log_line("VPN DNS 실패: %s", name);
    c->resolving = false;
    close_connection(c);
    return;
  }
  connect_ip(c, address);
}

static void start_connection(struct connection *c) {
  if (!link_up) { log_line("PPP 연결 전 요청 거부: %s:%d", c->host, c->port); close_connection(c); return; }
  ip_addr_t address;
  if (ipaddr_aton(c->host, &address)) {
    if (!IP_IS_V4(&address)) { close_connection(c); return; }
    connect_ip(c, &address);
    return;
  }
  c->phase = RESOLVING;
  c->resolving = true;
  err_t result = dns_gethostbyname(c->host, &address, dns_done, c);
  if (result == ERR_OK) connect_ip(c, &address);
  else if (result != ERR_INPROGRESS) { c->resolving = false; close_connection(c); }
}

static bool valid_port(int value) { return value > 0 && value <= 65535; }

static bool read_password(const char *fifo_path) {
  if (!fifo_path) return fgets(vpn_password, sizeof(vpn_password), stdin) != NULL;
  int fd = open(fifo_path, O_RDONLY | O_NONBLOCK);
  if (fd < 0) return false;
  struct stat info;
  if (fstat(fd, &info) || !S_ISFIFO(info.st_mode)) { close(fd); return false; }
  size_t used = 0;
  u32_t deadline = sys_now() + 15000;
  bool done = false;
  while ((int32_t)(deadline - sys_now()) > 0 && used < sizeof(vpn_password)-1) {
    ssize_t n = read(fd, vpn_password+used, sizeof(vpn_password)-1-used);
    if (n > 0) {
      used += (size_t)n;
      if (memchr(vpn_password, '\n', used)) { done = true; break; }
    } else if (n < 0 && errno != EAGAIN && errno != EINTR) break;
    usleep(50000);
  }
  close(fd);
  vpn_password[used] = 0;
  return done;
}

static bool set_target(struct connection *c, const char *host, int port) {
  size_t length = strlen(host);
  if (!length || length >= sizeof(c->host) || !valid_port(port)) return false;
  memcpy(c->host, host, length+1);
  c->port = port;
  return true;
}

static bool parse_authority(const char *authority, char *host, size_t host_capacity, int *port, int default_port) {
  const char *colon = strrchr(authority, ':');
  size_t host_len = colon ? (size_t)(colon - authority) : strlen(authority);
  if (!host_len || host_len >= host_capacity || strchr(authority, '@') || strchr(authority, '[')) return false;
  memcpy(host, authority, host_len);
  host[host_len] = 0;
  if (!colon) { *port = default_port; return true; }
  char *end = NULL;
  long parsed = strtol(colon+1, &end, 10);
  if (!end || *end || parsed < 1 || parsed > 65535) return false;
  *port = (int)parsed;
  return true;
}

static bool parse_http(struct connection *c) {
  if (c->header_len >= sizeof(c->header)) return false;
  c->header[c->header_len] = 0;
  char *line_end = strstr((char *)c->header, "\r\n");
  if (!line_end) return false;
  size_t first_len = (size_t)(line_end - (char *)c->header);
  if (first_len > 2048) return false;
  char first[2050];
  memcpy(first, c->header, first_len);
  first[first_len] = 0;
  char method[20], uri[2048], version[20];
  if (sscanf(first, "%19s %2047s %19s", method, uri, version) != 3) return false;
  if (strncmp(version, "HTTP/1.", 7)) return false;
  char host[256];
  int port;
  if (!strcmp(method, "CONNECT")) {
    if (!parse_authority(uri, host, sizeof(host), &port, 443)) return false;
    c->http_connect = true;
    if (!set_target(c, host, port)) return false;
    char *end_of_headers = strstr((char *)c->header, "\r\n\r\n");
    if (!end_of_headers) return false;
    size_t consumed = (size_t)(end_of_headers - (char *)c->header) + 4;
    if (c->header_len > consumed && !append_bytes(c->to_remote, &c->remote_len,
                                                  sizeof(c->to_remote), c->header+consumed,
                                                  c->header_len-consumed)) return false;
  } else {
    if (strncmp(uri, "http://", 7)) return false;
    const char *authority = uri+7;
    const char *slash = strpbrk(authority, "/?");
    char authority_copy[256];
    size_t authority_len = slash ? (size_t)(slash-authority) : strlen(authority);
    if (!authority_len || authority_len >= sizeof(authority_copy)) return false;
    memcpy(authority_copy, authority, authority_len);
    authority_copy[authority_len] = 0;
    if (!parse_authority(authority_copy, host, sizeof(host), &port, 80)) return false;
    if (!set_target(c, host, port)) return false;
    char query_path[2048];
    const char *path = slash ? slash : "/";
    if (slash && *slash == '?') {
      int path_len = snprintf(query_path, sizeof(query_path), "/%s", slash);
      if (path_len < 0 || (size_t)path_len >= sizeof(query_path)) return false;
      path = query_path;
    }
    char new_first[4096];
    int size = snprintf(new_first, sizeof(new_first), "%s %s %s\r\n", method, path, version);
    if (size < 0 || (size_t)size >= sizeof(new_first)) return false;
    size_t rest_len = c->header_len - (first_len+2);
    if ((size_t)size + rest_len > sizeof(c->to_remote)) return false;
    memcpy(c->to_remote, new_first, (size_t)size);
    memcpy(c->to_remote + size, line_end+2, rest_len);
    c->remote_len = (size_t)size + rest_len;
  }
  start_connection(c);
  return true;
}

static bool parse_socks_request(struct connection *c) {
  if (c->header_len < 4) return true;
  const uint8_t *b = c->header;
  if (b[0] != 5 || b[1] != 1 || b[2] != 0) return false;
  size_t offset = 4, host_len;
  char host[256];
  if (b[3] == 1) {
    host_len = 4;
    if (c->header_len < offset+host_len+2) return true;
    struct in_addr addr;
    memcpy(&addr, b+offset, 4);
    if (!inet_ntop(AF_INET, &addr, host, sizeof(host))) return false;
  } else if (b[3] == 3) {
    if (c->header_len < 5) return true;
    host_len = b[offset++];
    if (!host_len) return false;
    if (c->header_len < offset+host_len+2) return true;
    memcpy(host, b+offset, host_len);
    host[host_len] = 0;
  } else return false;
  offset += host_len;
  int port = ((int)b[offset]<<8) | b[offset+1];
  if (!set_target(c, host, port)) return false;
  size_t remaining = c->header_len - (offset+2);
  if (remaining && !append_bytes(c->to_remote, &c->remote_len, sizeof(c->to_remote), b+offset+2, remaining)) return false;
  c->header_len = 0;
  start_connection(c);
  return true;
}

static bool feed_local(struct connection *c, const uint8_t *data, size_t length) {
  if (c->phase == STREAMING || c->phase == CONNECTING || c->phase == RESOLVING) {
    return append_bytes(c->to_remote, &c->remote_len, sizeof(c->to_remote), data, length);
  }
  if (c->header_len + length >= sizeof(c->header)) return false;
  memcpy(c->header + c->header_len, data, length);
  c->header_len += length;
  c->header[c->header_len] = 0;
  if (c->phase == SOCKS_GREETING) {
    if (c->header_len < 2) return true;
    size_t greeting_len = 2 + c->header[1];
    if (greeting_len > c->header_len) return true;
    bool no_auth = false;
    for (size_t i=2; i<greeting_len; ++i) if (c->header[i] == 0) no_auth = true;
    if (c->header[0] != 5 || !no_auth) return false;
    static const uint8_t response[] = {5,0};
    if (!local_reply(c, response, sizeof(response))) return false;
    memmove(c->header, c->header+greeting_len, c->header_len-greeting_len);
    c->header_len -= greeting_len;
    c->phase = SOCKS_REQUEST;
  }
  if (c->phase == SOCKS_REQUEST) return parse_socks_request(c);
  if (c->phase == PROXY_HEADER && strstr((char *)c->header, "\r\n\r\n")) return parse_http(c);
  return true;
}

static void flush_local(struct connection *c) {
  if (c->fd < 0 || !c->local_len) return;
  ssize_t written = write(c->fd, c->to_local, c->local_len);
  if (written > 0) {
    memmove(c->to_local, c->to_local+written, c->local_len-(size_t)written);
    c->local_len -= (size_t)written;
    if (c->remote_closed && !c->local_len) close_connection(c);
  } else if (written < 0 && errno != EAGAIN && errno != EINTR) close_connection(c);
}

static void accept_client(struct listener *listener) {
  for (;;) {
    int fd = accept(listener->fd, NULL, NULL);
    if (fd < 0) { if (errno != EAGAIN && errno != EINTR) log_line("accept 오류: %s", strerror(errno)); return; }
    if (nonblocking(fd)) { close(fd); continue; }
    struct connection *c = NULL;
    for (size_t i=0; i<MAX_CONNECTIONS; ++i)
      if (connections[i].fd < 0 && !connections[i].resolving) { c = &connections[i]; break; }
    if (!c) { close(fd); continue; }
    memset(c, 0, sizeof(*c));
    c->fd = fd;
    c->kind = listener->kind;
    c->phase = listener->kind == SOCKS_PROXY ? SOCKS_GREETING : PROXY_HEADER;
    if (listener->kind == FORWARD) {
      if (!set_target(c, listener->remote_host, listener->remote_port)) close_connection(c);
      else start_connection(c);
    }
  }
}

static u32_t ppp_output(ppp_pcb *pcb, const void *data, u32_t length, void *ctx) {
  (void)pcb; (void)ctx;
  const uint8_t *bytes = data;
  size_t sent = 0;
  while (sent < length) {
    ssize_t n = write(pty_fd, bytes+sent, length-sent);
    if (n > 0) sent += (size_t)n;
    else if (n < 0 && errno == EINTR) continue;
    else { log_line("PPTP 전송 실패: %s", strerror(errno)); break; }
  }
  return (u32_t)sent;
}

static void ppp_status(ppp_pcb *pcb, int status, void *ctx) {
  (void)ctx;
  bool was_up = link_up;
  link_up = status == PPPERR_NONE &&
            pcb->ccp_transmit_method == CI_MPPE &&
            pcb->ccp_receive_method == CI_MPPE;
  if (link_up) {
    if (!was_up) {
      connected_since_ms = monotonic_ms();
      sent_bytes = 0;
      received_bytes = 0;
    }
    char address[32], gateway[32];
    ip4addr_ntoa_r(netif_ip4_addr(&ppp_netif), address, sizeof(address));
    ip4addr_ntoa_r(netif_ip4_gw(&ppp_netif), gateway, sizeof(gateway));
    log_line("PPP/MPPE 연결됨: %s → %s", address, gateway);
  } else {
    connected_since_ms = 0;
    if (status == PPPERR_NONE) log_line("PPP 주소 협상 완료, MPPE 협상 미완료");
    else log_line("PPP 연결 종료/실패: %d", status);
    for (size_t i=0; i<MAX_CONNECTIONS; ++i) if (connections[i].fd >= 0) close_connection(&connections[i]);
  }
}

static bool add_listener(enum listener_kind kind, int local_port, const char *host, int remote_port) {
  if (listener_count == MAX_LISTENERS || !valid_port(local_port)) return false;
  for (size_t i=0; i<listener_count; ++i) if (listeners[i].local_port == local_port) return false;
  struct listener *l = &listeners[listener_count++];
  l->fd = -1;
  l->kind = kind;
  l->local_port = local_port;
  l->remote_port = remote_port;
  if (host) snprintf(l->remote_host, sizeof(l->remote_host), "%s", host);
  return true;
}

static bool parse_forward(const char *spec) {
  char copy[512];
  if (strlen(spec) >= sizeof(copy)) return false;
  strcpy(copy, spec);
  char *first = strchr(copy, ':');
  char *last = strrchr(copy, ':');
  if (!first || first == last) return false;
  *first++ = 0;
  *last++ = 0;
  char *end1, *end2;
  long local_port = strtol(copy, &end1, 10);
  long remote_port = strtol(last, &end2, 10);
  if (*end1 || *end2 || !*first || strlen(first) >= 256 ||
      local_port < 1 || local_port > 65535 || remote_port < 1 || remote_port > 65535) return false;
  return add_listener(FORWARD, (int)local_port, first, (int)remote_port);
}

static bool parse_port_number(const char *text, int *result) {
  if (!text || !*text) return false;
  for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return false;
  errno = 0;
  char *end;
  long value = strtol(text, &end, 10);
  if (errno || *end || value < 1 || value > 65535) return false;
  *result = (int)value;
  return true;
}

static bool safe_host(const char *host) {
  size_t length = strlen(host);
  if (!length || length >= sizeof(listeners[0].remote_host)) return false;
  for (const char *p = host; *p; ++p) {
    if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
          (*p >= '0' && *p <= '9') || *p == '.' || *p == '-' || *p == '_')) return false;
  }
  return true;
}

static bool reconfigure_listeners(struct listener *requested, size_t count, int *failed_port) {
  int opened[MAX_LISTENERS];
  size_t opened_count = 0;
  for (size_t i = 0; i < count; ++i) {
    requested[i].fd = -1;
    for (size_t j = 0; j < listener_count; ++j) {
      if (listeners[j].local_port == requested[i].local_port) {
        requested[i].fd = listeners[j].fd;
        break;
      }
    }
    if (requested[i].fd < 0) {
      requested[i].fd = listen_loopback(requested[i].local_port);
      if (requested[i].fd < 0) {
        *failed_port = requested[i].local_port;
        for (size_t j = 0; j < opened_count; ++j) close(opened[j]);
        return false;
      }
      opened[opened_count++] = requested[i].fd;
    }
  }
  for (size_t i = 0; i < listener_count; ++i) {
    bool kept = false;
    for (size_t j = 0; j < count; ++j) {
      if (listeners[i].fd == requested[j].fd) { kept = true; break; }
    }
    if (!kept) close(listeners[i].fd);
  }
  memcpy(listeners, requested, count * sizeof(*requested));
  listener_count = count;
  log_line("프락시 설정 적용: HTTP %d, SOCKS5 %d, 포워딩 %zu개",
           listeners[0].local_port, listeners[1].local_port, count - 2);
  return true;
}

static bool apply_request(char *request, int *failed_port) {
  struct listener requested[MAX_LISTENERS] = {0};
  size_t count = 0;
  char *lines = NULL;
  char *line = strtok_r(request, "\n", &lines);
  if (!line) return false;
  char *fields = NULL;
  char *command = strtok_r(line, " ", &fields);
  char *http_text = strtok_r(NULL, " ", &fields);
  char *socks_text = strtok_r(NULL, " ", &fields);
  if (!command || strcmp(command, "APPLY") || !http_text || !socks_text ||
      strtok_r(NULL, " ", &fields)) return false;
  int http, socks;
  if (!parse_port_number(http_text, &http) || !parse_port_number(socks_text, &socks) || http == socks) return false;
  requested[count++] = (struct listener){ .fd = -1, .kind = HTTP_PROXY, .local_port = http };
  requested[count++] = (struct listener){ .fd = -1, .kind = SOCKS_PROXY, .local_port = socks };
  bool ended = false;
  while ((line = strtok_r(NULL, "\n", &lines)) != NULL) {
    fields = NULL;
    char *kind = strtok_r(line, " ", &fields);
    if (!kind) return false;
    if (!strcmp(kind, "END")) {
      if (strtok_r(NULL, " ", &fields) || strtok_r(NULL, "\n", &lines)) return false;
      ended = true;
      break;
    }
    if (strcmp(kind, "F") || count == MAX_LISTENERS) return false;
    char *local_text = strtok_r(NULL, " ", &fields);
    char *host = strtok_r(NULL, " ", &fields);
    char *remote_text = strtok_r(NULL, " ", &fields);
    if (!local_text || !host || !remote_text || strtok_r(NULL, " ", &fields) || !safe_host(host)) return false;
    int local, remote;
    if (!parse_port_number(local_text, &local) || !parse_port_number(remote_text, &remote)) return false;
    for (size_t i = 0; i < count; ++i) if (requested[i].local_port == local) return false;
    requested[count].fd = -1;
    requested[count].kind = FORWARD;
    requested[count].local_port = local;
    requested[count].remote_port = remote;
    strcpy(requested[count].remote_host, host);
    ++count;
  }
  return ended && reconfigure_listeners(requested, count, failed_port);
}

static void handle_control(int peer) {
  /* Accepted sockets can inherit O_NONBLOCK from the listening socket on macOS. */
  int flags = fcntl(peer, F_GETFL, 0);
  if (flags < 0 || fcntl(peer, F_SETFL, flags & ~O_NONBLOCK) < 0) { close(peer); return; }
  struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
  setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  char request[MAX_CONTROL_REQUEST];
  size_t length = 0;
  while (length < sizeof(request)-1) {
    ssize_t n = read(peer, request + length, sizeof(request)-1-length);
    if (n > 0) length += (size_t)n;
    else if (n == 0) break;
    else if (errno == EINTR) continue;
    else { length = 0; break; }
  }
  request[length] = 0;
  if (!length) { close(peer); return; }
  if (!strcmp(request, "STOP\n")) {
    (void)write(peer, "OK STOP\n", 8);
    log_line("연결 해제 요청 수신");
    stop_requested = 1;
  } else if (!strcmp(request, "STATUS\n")) {
    uint64_t elapsed = link_up && connected_since_ms ?
      (monotonic_ms() - connected_since_ms) / 1000 : 0;
    char reply[256];
    int n = snprintf(reply, sizeof(reply), "STATUS %d %" PRIu64 " %" PRIu64 " %" PRIu64 " %d %d\n",
                     link_up ? 1 : 0, sent_bytes, received_bytes, elapsed,
                     listeners[0].local_port, listeners[1].local_port);
    if (n > 0) (void)write(peer, reply, (size_t)n);
  } else if (!strncmp(request, "APPLY ", 6)) {
    int failed_port = 0;
    if (apply_request(request, &failed_port)) (void)write(peer, "OK APPLY\n", 9);
    else {
      char reply[64];
      int n = snprintf(reply, sizeof(reply), "ERR APPLY %d\n", failed_port);
      (void)write(peer, reply, (size_t)n);
    }
  } else (void)write(peer, "ERR COMMAND\n", 12);
  close(peer);
}

static void usage(void) {
  fprintf(stderr, "사용법: pptp-proxy --server HOST --user USER --pptp /path/to/pptp [--password-fifo PATH] [--control-socket PATH] [--http PORT] [--socks PORT] [--forward LOCAL:HOST:REMOTE]...\nVPN 암호는 표준입력 또는 지정된 FIFO의 첫 줄로 받습니다. GRE raw socket을 여는 실행 권한이 필요합니다.\n");
}

int main(int argc, char **argv) {
  const char *server = NULL, *user = NULL, *pptp_path = NULL, *password_fifo = NULL;
  int http_port = 18080, socks_port = 11080;
  char forward_specs[32][512];
  size_t forward_count = 0;
  for (int i=1; i<argc; ++i) {
    if (!strcmp(argv[i], "--server") && i+1<argc) server = argv[++i];
    else if (!strcmp(argv[i], "--user") && i+1<argc) user = argv[++i];
    else if (!strcmp(argv[i], "--pptp") && i+1<argc) pptp_path = argv[++i];
    else if (!strcmp(argv[i], "--password-fifo") && i+1<argc) password_fifo = argv[++i];
    else if (!strcmp(argv[i], "--control-socket") && i+1<argc) control_socket_path = argv[++i];
    else if (!strcmp(argv[i], "--http") && i+1<argc) http_port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--socks") && i+1<argc) socks_port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--forward") && i+1<argc && forward_count<32) snprintf(forward_specs[forward_count++], 512, "%s", argv[++i]);
    else { usage(); return 2; }
  }
  if (!server || !user || !pptp_path || !*server || !*user || !valid_port(http_port) || !valid_port(socks_port)) { usage(); return 2; }
  if (!add_listener(HTTP_PROXY, http_port, NULL, 0) || !add_listener(SOCKS_PROXY, socks_port, NULL, 0)) { usage(); return 2; }
  for (size_t i=0; i<forward_count; ++i) if (!parse_forward(forward_specs[i])) { usage(); return 2; }
  for (size_t i=0; i<MAX_CONNECTIONS; ++i) connections[i].fd = -1;
  if (control_socket_path) {
    control_fd = listen_control(control_socket_path);
    if (control_fd < 0) { log_line("제어 소켓 생성 실패: %s", strerror(errno)); return 1; }
    atexit(cleanup_control_socket);
  }
  if (!read_password(password_fifo)) { log_line("VPN 암호 입력 실패 또는 시간 초과"); return 2; }
  vpn_password[strcspn(vpn_password, "\r\n")] = 0;
  if (!*vpn_password) { log_line("VPN 암호가 비어 있습니다"); return 2; }
  for (size_t i=0; i<listener_count; ++i) {
    listeners[i].fd = listen_loopback(listeners[i].local_port);
    if (listeners[i].fd < 0) { log_line("로컬 포트 %d 사용 실패: %s", listeners[i].local_port, strerror(errno)); return 1; }
  }
  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  signal(SIGPIPE, SIG_IGN);
  pptp_pid = forkpty(&pty_fd, NULL, NULL, NULL);
  if (pptp_pid < 0) { log_line("PPTP 실행 실패: %s", strerror(errno)); return 1; }
  if (pptp_pid == 0) {
    execl(pptp_path, pptp_path, server, "--nolaunchpppd", "--nohostroute", (char *)NULL);
    _exit(127);
  }
  struct termios term;
  if (tcgetattr(pty_fd, &term) == 0) { cfmakeraw(&term); tcsetattr(pty_fd, TCSANOW, &term); }
  lwip_init();
  ppp = pppos_create(&ppp_netif, ppp_output, ppp_status, NULL);
  if (!ppp) { log_line("PPP 초기화 실패"); return 1; }
  /* lwIP keeps pointers to these strings until authentication completes. */
  ppp_set_auth(ppp, PPPAUTHTYPE_MSCHAP_V2, user, vpn_password);
  ppp_set_mppe(ppp, PPP_MPPE_ENABLE | PPP_MPPE_REFUSE_40);
  ppp_set_usepeerdns(ppp, 1);
  ppp_set_default(ppp);
  if (ppp_connect(ppp, 0) != ERR_OK) { log_line("PPP 시작 실패"); return 1; }
  log_line("PPTP 서버 %s 연결 중", server);
  for (size_t i=0; i<listener_count; ++i) log_line("127.0.0.1:%d 대기", listeners[i].local_port);
  while (!stop_requested) {
    sys_check_timeouts();
    fd_set readfds, writefds;
    FD_ZERO(&readfds); FD_ZERO(&writefds);
    int maxfd = pty_fd;
    FD_SET(pty_fd, &readfds);
    if (control_fd >= 0) {
      FD_SET(control_fd, &readfds);
      if (control_fd > maxfd) maxfd = control_fd;
    }
    for (size_t i=0; i<listener_count; ++i) {
      FD_SET(listeners[i].fd, &readfds);
      if (listeners[i].fd > maxfd) maxfd = listeners[i].fd;
    }
    for (size_t i=0; i<MAX_CONNECTIONS; ++i) {
      struct connection *c = &connections[i];
      if (c->fd < 0) continue;
      if (c->phase != RESOLVING && c->phase != CONNECTING && c->remote_len < sizeof(c->to_remote)-8192 && c->local_len < sizeof(c->to_local)-8192) FD_SET(c->fd, &readfds);
      if (c->local_len) FD_SET(c->fd, &writefds);
      if (c->fd > maxfd) maxfd = c->fd;
      if (c->phase == STREAMING) flush_remote(c);
    }
    u32_t next = sys_timeouts_sleeptime();
    if (next > 100) next = 100;
    struct timeval timeout = { .tv_sec = next/1000, .tv_usec = (next%1000)*1000 };
    int ready = select(maxfd+1, &readfds, &writefds, NULL, &timeout);
    if (ready < 0) { if (errno == EINTR) continue; log_line("select 오류: %s", strerror(errno)); break; }
    if (FD_ISSET(pty_fd, &readfds)) {
      uint8_t data[8192];
      ssize_t n = read(pty_fd, data, sizeof(data));
      if (n > 0) pppos_input(ppp, data, (int)n);
      else if (n == 0 || (errno != EAGAIN && errno != EINTR)) { log_line("PPTP 프로세스 종료"); break; }
    }
    if (control_fd >= 0 && FD_ISSET(control_fd, &readfds)) {
      int peer = accept(control_fd, NULL, NULL);
      if (peer >= 0) handle_control(peer);
    }
    for (size_t i=0; i<listener_count; ++i) if (FD_ISSET(listeners[i].fd, &readfds)) accept_client(&listeners[i]);
    for (size_t i=0; i<MAX_CONNECTIONS; ++i) {
      struct connection *c = &connections[i];
      if (c->fd < 0) continue;
      if (FD_ISSET(c->fd, &writefds)) flush_local(c);
      if (c->fd < 0) continue;
      if (FD_ISSET(c->fd, &readfds)) {
        uint8_t data[8192];
        ssize_t n = read(c->fd, data, sizeof(data));
        if (n > 0) { if (!feed_local(c, data, (size_t)n)) close_connection(c); }
        else if (n == 0 || (errno != EAGAIN && errno != EINTR)) close_connection(c);
      }
    }
    int status;
    if (waitpid(pptp_pid, &status, WNOHANG) == pptp_pid) { pptp_pid = -1; log_line("PPTP 프로세스 종료 코드: %d", status); break; }
  }
  for (size_t i=0; i<MAX_CONNECTIONS; ++i) if (connections[i].fd >= 0) close_connection(&connections[i]);
  ppp_close(ppp, 0);
  if (pptp_pid > 0) {
    kill(pptp_pid, SIGTERM);
    bool reaped = false;
    for (int attempt = 0; attempt < 20; ++attempt) {
      pid_t result = waitpid(pptp_pid, NULL, WNOHANG);
      if (result == pptp_pid || (result < 0 && errno == ECHILD)) { reaped = true; break; }
      if (result < 0 && errno != EINTR) break;
      usleep(100000);
    }
    if (!reaped) { kill(pptp_pid, SIGKILL); waitpid(pptp_pid, NULL, 0); }
  }
  if (pty_fd >= 0) close(pty_fd);
  cleanup_control_socket();
  for (size_t i=0; i<listener_count; ++i) if (listeners[i].fd >= 0) close(listeners[i].fd);
  erase_secret(vpn_password, sizeof(vpn_password));
  log_line("PPTP 연결 종료");
  return 0;
}
