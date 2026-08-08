// SPDX-License-Identifier: GPL-2.0-only
/*
 * Supplicant for the QSEECOM file service, so trusted applications can reach
 * their secure storage.
 *
 * A QSEE application that needs to read or write a secure object blocks until
 * the normal world answers. The focal32 fingerprint application does this for
 * everything it persists -- templates, calibration, its serial id -- and with
 * nothing serving the request, every one of those fails:
 *
 *   qsee_sfs_open('/data/vendor_de/0/fpdata/ft_fp_serial_id.bin', ..)
 *       = 'SFS_ERROR_GENERIC: Generic failure error'
 *
 * so nothing can be enrolled, and there is nothing to match against.
 *
 * The arrangement is OP-TEE's tee-supplicant, and the driver says so: a
 * supplicant declares a service by opening a session on the privileged device
 * with the listener id in parameter 0 and the shared buffer in parameter 1,
 * then loops on TEE_IOC_SUPPL_RECV and TEE_IOC_SUPPL_SEND. Requests and
 * replies pass through that one buffer.
 *
 * Listener 10 is "file system services", read out of the vendor's
 * /vendor/bin/qseecomd, where a table pairs each service name with its id
 * eight bytes later. RPMB (0x2000) and SSD (0x3000) in that same table match
 * the vendor kernel's own defines, which is what confirms the layout.
 *
 * Nothing here is trusted with anything: the application encrypts and
 * integrity-protects every object before it crosses this boundary, which is
 * exactly why the I/O can be handed to an ordinary process.
 *
 * Build: cc -O2 -o ffsupplicant ffsupplicant.c
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <linux/tee.h>

/* Mirrors enum qseecom_listener_status in the kernel's qcom_scm.h. */
#define QSEECOM_LISTENER_SUCCESS	0
#define QSEECOM_LISTENER_FAILURE	1

#define PRIV_DEV		"/dev/teepriv0"
#define TEE_IMPL_ID_QSEECOM	5

/*
 * "gpfile system services" in /vendor/bin/qseecomd's listener table, and the
 * one the fingerprint application's SFS calls actually reach. Listener 10,
 * "file system services", is a different service and never sees them.
 */
#define FS_LISTENER_ID		28672

/*
 * The vendor's implementation of this service is /vendor/lib64/libdrmfs.so.
 * Its dispatcher reads a 32-bit opcode from the head of the request, answers
 * opcode 12 immediately -- before it even checks that the partition is
 * mounted -- and routes 0..11 through a jump table to the real file
 * operations. Opcode 12 is a handshake: refuse it and the application gives up
 * before it ever sends a path.
 */
#define GPFS_OP_HELLO		12

/*
 * The vendor answers it with the request buffer untouched: the store it makes
 * alongside goes to a stack scratch buffer, not the shared one, and the reply
 * is simply twelve bytes of whatever is already there. Copied rather than
 * invented -- mirroring libdrmfs.so is the only reason answering success here
 * is safe.
 */

/*
 * The vendor registers a 32 KiB buffer for this listener. The size is ours to
 * choose -- it is what TZ is told the buffer is -- but a request carrying a
 * path plus a block of file data needs room, and a short buffer would truncate
 * silently.
 */
#define SB_LEN			(32 * 1024)

/* Room for the handful of services a supplicant might offer at once. */
#define MAX_LISTENERS		64

static int verbose;

static void note(const char *fmt, ...)
{
	va_list ap;

	if (!verbose)
		return;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

static void dump(const void *p, size_t n, size_t max)
{
	const unsigned char *b = p;
	size_t i, j;

	if (n > max)
		n = max;

	for (i = 0; i < n; i += 16) {
		fprintf(stderr, "    %04zx  ", i);
		for (j = 0; j < 16 && i + j < n; j++)
			fprintf(stderr, "%02x ", b[i + j]);
		for (; j < 16; j++)
			fprintf(stderr, "   ");
		fprintf(stderr, " |");
		for (j = 0; j < 16 && i + j < n; j++)
			fprintf(stderr, "%c", (b[i + j] >= 0x20 &&
					       b[i + j] < 0x7f) ?
					      b[i + j] : '.');
		fprintf(stderr, "|\n");
	}
}

struct shm {
	int id;
	void *va;
	size_t size;
};

/* One service offered: its id, the buffer its requests arrive in, and the
 * session that withdraws it. */
struct service {
	uint32_t id;
	struct shm sb;
	uint32_t session;
};

static int shm_alloc(int fd, size_t size, struct shm *out)
{
	struct tee_ioctl_shm_alloc_data data = { .size = size };
	int shm_fd;

	shm_fd = ioctl(fd, TEE_IOC_SHM_ALLOC, &data);
	if (shm_fd < 0) {
		fprintf(stderr, "SHM_ALLOC(%zu): %s\n", size, strerror(errno));
		return -1;
	}

	out->va = mmap(NULL, data.size, PROT_READ | PROT_WRITE, MAP_SHARED,
		       shm_fd, 0);
	close(shm_fd);
	if (out->va == MAP_FAILED) {
		fprintf(stderr, "mmap: %s\n", strerror(errno));
		return -1;
	}

	out->id = data.id;
	out->size = data.size;
	memset(out->va, 0, data.size);

	return 0;
}

/*
 * The privileged device is the one that registers listeners; the client device
 * cannot. Which /dev/teeN belongs to this driver depends on what else probed
 * first, so ask rather than assume -- but only the privileged node will do.
 */
static int open_priv(void)
{
	struct tee_ioctl_version_data vers;
	int fd = open(PRIV_DEV, O_RDWR);

	if (fd < 0) {
		fprintf(stderr, "%s: %s\n", PRIV_DEV, strerror(errno));
		return -1;
	}

	if (ioctl(fd, TEE_IOC_VERSION, &vers) ||
	    vers.impl_id != TEE_IMPL_ID_QSEECOM) {
		fprintf(stderr, "%s is not the QSEECOM driver\n", PRIV_DEV);
		close(fd);
		return -1;
	}

	return fd;
}

/*
 * Register the service. A null UUID plus {value, memref} is how the driver
 * tells a listener registration from an application load, and the session it
 * hands back is what withdraws the service when closed.
 */
static int register_listener(int fd, uint32_t id, struct shm *sb,
			     uint32_t *session)
{
	struct {
		struct tee_ioctl_open_session_arg arg;
		struct tee_ioctl_param params[2];
	} buf = {};
	struct tee_ioctl_buf_data bd;

	buf.arg.num_params = 2;
	buf.arg.clnt_login = TEE_IOCTL_LOGIN_PUBLIC;

	buf.params[0].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
	buf.params[0].a = id;

	buf.params[1].attr = TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INOUT;
	buf.params[1].b = sb->size;
	buf.params[1].c = sb->id;

	bd.buf_ptr = (uintptr_t)&buf;
	bd.buf_len = sizeof(buf);

	if (ioctl(fd, TEE_IOC_OPEN_SESSION, &bd)) {
		fprintf(stderr, "OPEN_SESSION(listener %u): %s\n", id,
			strerror(errno));
		return -1;
	}

	if (buf.arg.ret) {
		fprintf(stderr, "listener %u refused: ret=0x%x origin=0x%x\n",
			id, buf.arg.ret, buf.arg.ret_origin);
		return -1;
	}

	*session = buf.arg.session;

	return 0;
}

static void close_session(int fd, uint32_t session)
{
	struct tee_ioctl_close_session_arg arg = { .session = session };

	if (ioctl(fd, TEE_IOC_CLOSE_SESSION, &arg))
		fprintf(stderr, "CLOSE_SESSION: %s\n", strerror(errno));
}

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

int main(int argc, char **argv)
{
	struct service svc[MAX_LISTENERS] = {};
	unsigned int nsvc = 0;
	int fd, i;
	unsigned long served = 0;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!strcmp(argv[i], "--listener") && i + 1 < argc) {
			if (nsvc == MAX_LISTENERS) {
				fprintf(stderr, "at most %d listeners\n",
					MAX_LISTENERS);
				return 2;
			}
			svc[nsvc++].id = strtoul(argv[++i], NULL, 0);
		} else if (!strcmp(argv[i], "--range") && i + 1 < argc) {
			/*
			 * Offer every id in a range, to find which service a
			 * secure-world caller actually reaches. Registration
			 * of an id already taken fails, so this skips those
			 * rather than giving up.
			 */
			unsigned long lo, hi;
			char *dash;

			lo = strtoul(argv[++i], &dash, 0);
			hi = (dash && *dash == '-') ? strtoul(dash + 1, NULL, 0)
						    : lo;
			for (; lo <= hi && nsvc < MAX_LISTENERS; lo++)
				svc[nsvc++].id = lo;
		} else {
			fprintf(stderr,
				"usage: ffsupplicant [-v] [--listener N]...\n"
				"                    [--range A-B]...\n"
				"  -v            dump every request and reply\n"
				"  --listener N  service to offer, repeatable\n"
				"                (default %u, \"gpfile system\n"
				"                services\")\n"
				"  --range A-B   offer every id in a range, to\n"
				"                find which service a caller\n"
				"                actually reaches; ids that do\n"
				"                not register are skipped\n"
				"\n"
				"Only one process can receive: the driver hands\n"
				"requests to whichever context asks first, so a\n"
				"supplicant must offer every service it serves\n"
				"itself rather than running one per listener.\n"
				"\n"
				"TrustZone also caps how many listeners exist at\n"
				"once -- around two dozen -- so a wide --range\n"
				"can crowd out the ids that matter and look like\n"
				"a service that never fires. Offer few.\n",
				FS_LISTENER_ID);
			return 2;
		}
	}

	if (!nsvc)
		svc[nsvc++].id = FS_LISTENER_ID;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	fd = open_priv();
	if (fd < 0)
		return 1;

	for (i = 0; i < (int)nsvc; i++) {
		if (shm_alloc(fd, SB_LEN, &svc[i].sb)) {
			close(fd);
			return 1;
		}

		if (register_listener(fd, svc[i].id, &svc[i].sb,
				      &svc[i].session)) {
			/*
			 * An id already registered, or one TZ will not hand
			 * out, is not fatal when sweeping a range: drop it and
			 * keep the rest.
			 */
			svc[i].id = 0;
			continue;
		}

		printf("listener %u registered, buffer %zu bytes\n",
		       svc[i].id, svc[i].sb.size);
	}

	printf("waiting for requests\n");
	fflush(stdout);

	while (!stop) {
		struct {
			struct tee_iocl_supp_recv_arg arg;
			struct tee_ioctl_param params[2];
		} rx = {};
		struct {
			struct tee_iocl_supp_send_arg arg;
			struct tee_ioctl_param params[2];
		} tx = {};
		struct tee_ioctl_buf_data bd;
		struct service *cur;
		uint32_t gen;

		rx.arg.num_params = 2;
		bd.buf_ptr = (uintptr_t)&rx;
		bd.buf_len = sizeof(rx);

		if (ioctl(fd, TEE_IOC_SUPPL_RECV, &bd)) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "SUPPL_RECV: %s\n", strerror(errno));
			break;
		}

		/*
		 * param[0] carries the generation this request was handed out
		 * with, and the answer has to echo it back: a supplicant that
		 * overran the timeout would otherwise apply its answer to
		 * whatever request took the slot in the meantime.
		 */
		gen = rx.params[0].a;

		/*
		 * Which service the request is for. The buffer it arrives in
		 * is that listener's own, so the id is how a supplicant
		 * offering several of them knows where to look.
		 */
		cur = NULL;
		for (i = 0; i < (int)nsvc; i++)
			if (svc[i].id == rx.arg.func)
				cur = &svc[i];

		served++;
		{
			uint32_t op = 0;

			if (cur && cur->sb.size >= 4)
				memcpy(&op, cur->sb.va, sizeof(op));

			printf("\n=== request %lu on listener %u, opcode %u "
			       "(generation %u)\n",
			       served, rx.arg.func, op, gen);
		}
		if (cur)
			dump(cur->sb.va, cur->sb.size, 256);
		else
			printf("    (no buffer for listener %u?)\n",
			       rx.arg.func);
		fflush(stdout);

		/*
		 * Anything not understood is refused rather than answered
		 * with a claim of success: the application would go on
		 * believing it had read or written its object, and a bogus
		 * success is what wedges the secure world.
		 */
		tx.arg.ret = QSEECOM_LISTENER_FAILURE;

		if (cur && cur->sb.size >= 12) {
			uint32_t op;

			memcpy(&op, cur->sb.va, sizeof(op));

			if (op == GPFS_OP_HELLO) {
				tx.arg.ret = QSEECOM_LISTENER_SUCCESS;
				note("opcode %u: handshake answered\n", op);
			} else {
				note("opcode %u: not implemented, refusing\n",
				     op);
			}
		}
		tx.arg.num_params = 2;
		tx.params[0].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
		tx.params[0].a = gen;
		tx.params[1].attr = TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INOUT;
		tx.params[1].b = cur ? cur->sb.size : 0;
		tx.params[1].c = cur ? cur->sb.id : 0;

		bd.buf_ptr = (uintptr_t)&tx;
		bd.buf_len = sizeof(tx);

		if (ioctl(fd, TEE_IOC_SUPPL_SEND, &bd)) {
			fprintf(stderr, "SUPPL_SEND: %s\n", strerror(errno));
			break;
		}

		note("answered request %lu\n", served);
	}

	printf("\nserved %lu request(s), withdrawing\n", served);
	for (i = 0; i < (int)nsvc; i++)
		close_session(fd, svc[i].session);
	close(fd);

	return 0;
}
