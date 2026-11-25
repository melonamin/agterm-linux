#ifndef AGTERM_LINUX_SOCKET_DIAG_H
#define AGTERM_LINUX_SOCKET_DIAG_H
#include <errno.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/unix_diag.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    uint32_t socket_inode;
    uint32_t filesystem_inode;
} agterm_unix_listener_t;

static inline int64_t agterm_socket_clock_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

// One bounded kernel dump, never a request to a daemon. VFS identity survives unlinking the bind path.
// Return no partial result on a timeout, interrupted dump, overflow or malformed reply.
static inline int agterm_unix_listeners(agterm_unix_listener_t *output, size_t capacity)
{
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, NETLINK_SOCK_DIAG);
    if (fd < 0) return -1;
    int count = -1;
    struct { struct nlmsghdr header; struct unix_diag_req request; } query = {0};
    query.header.nlmsg_len = sizeof(query);
    query.header.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    query.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    query.header.nlmsg_seq = 1;
    query.request.sdiag_family = AF_UNIX;
    query.request.udiag_states = 1U << 10; // TCP_LISTEN, the Unix stream listener's diagnostic state.
    query.request.udiag_show = UDIAG_SHOW_VFS;
    struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
    if (sendto(fd, &query, sizeof(query), 0, (struct sockaddr *)&kernel, sizeof(kernel)) != sizeof(query)) goto done;
    int64_t deadline = agterm_socket_clock_ms() + 100;
    size_t total = 0, entries = 0;
    while (agterm_socket_clock_ms() < deadline && total < 16 * 1024 * 1024) {
        struct pollfd ready = { .fd = fd, .events = POLLIN };
        int remaining = (int)(deadline - agterm_socket_clock_ms());
        if (remaining <= 0 || poll(&ready, 1, remaining) <= 0) goto done;
        // A union provides alignment for netlink headers and attributes.
        union { struct nlmsghdr alignment; unsigned char bytes[65536]; } buffer;
        ssize_t length = recv(fd, buffer.bytes, sizeof(buffer.bytes), MSG_TRUNC);
        if (length < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (length <= 0 || (size_t)length > sizeof(buffer.bytes)) goto done;
        total += length;
        int left = (int)length;
        for (struct nlmsghdr *header = (struct nlmsghdr *)buffer.bytes; NLMSG_OK(header, left); header = NLMSG_NEXT(header, left)) {
            if (header->nlmsg_seq != 1 || (header->nlmsg_flags & NLM_F_DUMP_INTR)) goto done;
            if (header->nlmsg_type == NLMSG_DONE) {
                if (header->nlmsg_len >= NLMSG_LENGTH(sizeof(int)) && *(int *)NLMSG_DATA(header) != 0) goto done;
                count = (int)entries;
                goto done;
            }
            if (header->nlmsg_type != SOCK_DIAG_BY_FAMILY || header->nlmsg_len < NLMSG_LENGTH(sizeof(struct unix_diag_msg))) goto done;
            struct unix_diag_msg *socket = NLMSG_DATA(header);
            if (socket->udiag_family != AF_UNIX || socket->udiag_type != SOCK_STREAM || socket->udiag_state != 10) continue;
            int attributes = header->nlmsg_len - NLMSG_LENGTH(sizeof(*socket));
            struct rtattr *attribute = (struct rtattr *)((unsigned char *)socket + NLMSG_ALIGN(sizeof(*socket)));
            for (; RTA_OK(attribute, attributes); attribute = RTA_NEXT(attribute, attributes)) {
                if (attribute->rta_type != UNIX_DIAG_VFS) continue;
                if (RTA_PAYLOAD(attribute) != sizeof(struct unix_diag_vfs) || entries >= capacity) goto done;
                struct unix_diag_vfs *file = RTA_DATA(attribute);
                output[entries++] = (agterm_unix_listener_t){ socket->udiag_ino, file->udiag_vfs_ino };
            }
            if (attributes != 0) goto done;
        }
        if (left != 0) goto done;
    }
 done:
    close(fd);
    return count;
}
#endif
