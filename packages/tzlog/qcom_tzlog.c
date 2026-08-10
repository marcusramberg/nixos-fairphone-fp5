// SPDX-License-Identifier: GPL-2.0-only
/*
 * Read TrustZone's diagnostic area.
 *
 * QSEE records what it is doing -- including the fault that killed a trusted
 * application -- in a small region of carved-out memory that the normal world
 * may read but not write. Qualcomm's own tz_log driver exposes it as
 * files under /sys/kernel/debug/tzdbg, but that driver lives in a vendor tree
 * rather than
 * in mainline, so an application fault here surfaces as nothing more than an
 * SCM call returning an error the driver has no name for.
 *
 * This exposes the region raw, at /sys/kernel/debug/tzlog/raw, and leaves the
 * decoding to whatever reads it. A fault record carries the faulting address
 * and program counter, which is what turns "the application died somewhere"
 * into a single instruction.
 *
 * The address comes from the FP5 vendor device tree:
 *
 *	tz-log@0x146aa720 {
 *		compatible = "qcom,tz-log";
 *		reg = <0x146aa720 0x3000>;
 *	};
 *
 * It is a module parameter rather than a device tree lookup so this can be
 * loaded against a kernel whose device tree has no such node, which is every
 * mainline one.
 */

#include <linux/arm-smccc.h>
#include <linux/dma-mapping.h>
#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/types.h>

/*
 * Qualcomm's SCM calling convention, as the vendor kernel builds it: x0 is a
 * standard SMCCC function id whose function number is the service and command
 * packed together, x1 describes the argument types, and the arguments follow.
 *
 * Only the two calls that concern the log are here. The generic entry point in
 * mainline's qcom_scm is static, so a module has to make the call itself.
 */
#define QCOM_SCM_SVC_QSEELOG		0x01
#define QCOM_SCM_QSEELOG_REGISTER	0x06
#define QCOM_SCM_QUERY_ENCR_LOG_FEAT_ID	0x0b
#define QCOM_SCM_REQUEST_ENCR_LOG_ID	0x0c

/*
 * The application log is a separate thing from the diagnostic area: QSEE writes
 * what trusted applications say -- and what it says about them when one of them
 * dies -- into a buffer the normal world registers with it. Nothing appears
 * there until someone asks, which is why an application fault has looked
 * silent.
 *
 * The buffer opens with the ring's position, and the text follows.
 */
#define QSEE_LOG_BUF_SIZE		0x8000

struct qsee_log_pos {
	u16 wrap;
	u16 offset;
};

#define TZLOG_FNID(svc, cmd)		((((svc) & 0xff) << 8) | ((cmd) & 0xff))

/* Argument descriptor: count in the low nibble, then two bits per argument. */
#define TZLOG_ARG_VAL			0x0
#define TZLOG_ARG_RW			0x2

static u64 tzlog_smc(u32 svc, u32 cmd, u64 arginfo, u64 a0, u64 a1, u64 a2,
		     struct arm_smccc_res *res)
{
	u32 fn = ARM_SMCCC_CALL_VAL(ARM_SMCCC_FAST_CALL, ARM_SMCCC_SMC_64,
				    ARM_SMCCC_OWNER_TRUSTED_OS,
				    TZLOG_FNID(svc, cmd));

	arm_smccc_smc(fn, arginfo, a0, a1, a2, 0, 0, 0, res);

	return res->a0;
}

static unsigned long long tzlog_base = 0x146aa720;
module_param_named(base, tzlog_base, ullong, 0444);
MODULE_PARM_DESC(base, "physical address of TrustZone's diagnostic area");

static unsigned long tzlog_size = 0x3000;
module_param_named(size, tzlog_size, ulong, 0444);
MODULE_PARM_DESC(size, "size of TrustZone's diagnostic area in bytes");

static void __iomem *tzlog_va;
static struct dentry *tzlog_dir;

/*
 * Copy out of the mapping before handing anything to user space.
 *
 * Two things this region will not tolerate: a cacheable mapping, which takes an
 * external abort on the first read, and being copied straight to user space,
 * which is what debugfs_create_blob() does and why it cannot be used here.
 */
static ssize_t tzlog_read(struct file *file, char __user *buf, size_t len,
			  loff_t *ppos)
{
	ssize_t ret;
	size_t i;
	void *tmp;

	if (*ppos >= tzlog_size)
		return 0;

	tmp = kmalloc(tzlog_size, GFP_KERNEL);
	if (!tmp)
		return -ENOMEM;

	/*
	 * A word at a time, aligned. The region lives in the SoC's on-chip
	 * memory, which only answers aligned 32-bit accesses -- memcpy_fromio()
	 * uses wider loads and takes an external abort on the first one.
	 */
	for (i = 0; i < tzlog_size / sizeof(u32); i++)
		((u32 *)tmp)[i] = readl_relaxed(tzlog_va + i * sizeof(u32));
	ret = simple_read_from_buffer(buf, len, ppos, tmp, tzlog_size);

	kfree(tmp);

	return ret;
}

static const struct file_operations tzlog_fops = {
	.owner	= THIS_MODULE,
	.read	= tzlog_read,
	.llseek	= default_llseek,
};

static struct platform_device *qsee_pdev;
static void *qsee_log;
static dma_addr_t qsee_log_dma;

static ssize_t qsee_read(struct file *file, char __user *buf, size_t len,
			 loff_t *ppos)
{
	return simple_read_from_buffer(buf, len, ppos, qsee_log,
				       QSEE_LOG_BUF_SIZE);
}

static const struct file_operations qsee_fops = {
	.owner	= THIS_MODULE,
	.read	= qsee_read,
	.llseek	= default_llseek,
};

/*
 * Hand QSEE somewhere to write its application log. The buffer has to be
 * coherent: the secure world writes it without going through our caches.
 */
static void qsee_log_register(void)
{
	struct arm_smccc_res res;
	u64 ret;

	qsee_pdev = platform_device_register_simple("tzlog", -1, NULL, 0);
	if (IS_ERR(qsee_pdev)) {
		pr_err("tzlog: no device for the application log\n");
		qsee_pdev = NULL;
		return;
	}

	if (dma_coerce_mask_and_coherent(&qsee_pdev->dev, DMA_BIT_MASK(64)))
		goto err;

	qsee_log = dma_alloc_coherent(&qsee_pdev->dev, QSEE_LOG_BUF_SIZE,
				      &qsee_log_dma, GFP_KERNEL);
	if (!qsee_log)
		goto err;

	ret = tzlog_smc(QCOM_SCM_SVC_QSEELOG, QCOM_SCM_QSEELOG_REGISTER,
			/* two arguments, the first a buffer QSEE writes */
			2 | (TZLOG_ARG_RW << 4),
			qsee_log_dma, QSEE_LOG_BUF_SIZE, 0, &res);

	pr_info("tzlog: application log at %pad, registered: ret=%llu result=%lu\n",
		&qsee_log_dma, ret, res.a1);

	debugfs_create_file("qsee", 0400, tzlog_dir, NULL, &qsee_fops);

	return;

err:
	if (qsee_log)
		dma_free_coherent(&qsee_pdev->dev, QSEE_LOG_BUF_SIZE, qsee_log,
				  qsee_log_dma);
	platform_device_unregister(qsee_pdev);
	qsee_pdev = NULL;
	qsee_log = NULL;
}

static int __init tzlog_init(void)
{
	void __iomem *ptr_va;
	u32 diag_phys;

	if (!tzlog_size)
		return -EINVAL;

	/*
	 * The device tree's address is not the log. It is a word in on-chip
	 * memory holding the physical address of the diagnostic buffer, which
	 * is what the vendor driver reads first:
	 *
	 *	tzdiag_phy_iobase = readl_relaxed(virt_iobase);
	 *
	 * Only that word is readable. Reading further walks off the end of the
	 * window and takes an external abort, which is exactly what happened
	 * when this mapped the whole 0x3000 and dumped it.
	 */
	ptr_va = ioremap(tzlog_base, sizeof(u32));
	if (!ptr_va)
		return -ENOMEM;

	diag_phys = readl_relaxed(ptr_va);
	iounmap(ptr_va);

	if (!diag_phys) {
		pr_err("tzlog: no diagnostic buffer address at %#llx\n",
		       tzlog_base);
		return -ENODEV;
	}

	/* Device memory: the buffer is carved out before Linux sees it. */
	tzlog_va = ioremap(diag_phys, tzlog_size);
	if (!tzlog_va) {
		pr_err("tzlog: cannot map %#x+%#lx\n", diag_phys, tzlog_size);
		return -ENOMEM;
	}

	pr_info("tzlog: diagnostic buffer at %#x (pointer read from %#llx)\n",
		diag_phys, tzlog_base);

	tzlog_dir = debugfs_create_dir("tzlog", NULL);
	debugfs_create_file("raw", 0400, tzlog_dir, NULL, &tzlog_fops);

	pr_info("tzlog: %#llx+%#lx at /sys/kernel/debug/tzlog/raw\n",
		tzlog_base, tzlog_size);

	/*
	 * Whether the log may be read at all. When TrustZone encrypts its log
	 * it also stops answering reads of the diagnostic area -- the vendor
	 * driver checks this first and only maps the area when the answer is
	 * no. An external abort on the mapping is what that refusal looks like
	 * from here, so report the answer plainly.
	 */
	{
		struct arm_smccc_res res;
		u64 ret = tzlog_smc(QCOM_SCM_SVC_QSEELOG,
				    QCOM_SCM_QUERY_ENCR_LOG_FEAT_ID,
				    0, 0, 0, 0, &res);

		pr_info("tzlog: encrypted-log feature: ret=%llu enabled=%lu\n",
			ret, res.a1);
	}

	qsee_log_register();

	return 0;
}

static void __exit tzlog_exit(void)
{
	debugfs_remove_recursive(tzlog_dir);
	iounmap(tzlog_va);

	if (qsee_log)
		dma_free_coherent(&qsee_pdev->dev, QSEE_LOG_BUF_SIZE, qsee_log,
				  qsee_log_dma);
	if (qsee_pdev)
		platform_device_unregister(qsee_pdev);
}

module_init(tzlog_init);
module_exit(tzlog_exit);

MODULE_DESCRIPTION("Raw access to TrustZone's diagnostic area");
MODULE_LICENSE("GPL");
