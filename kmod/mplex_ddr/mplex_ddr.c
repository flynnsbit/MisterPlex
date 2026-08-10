// mplex_ddr — write-combine / DMA bank window for MiSTerPlex present path.
#include <linux/version.h>
// Product track (DESIGN_CARD_KERNEL_DMA_720). Userspace PL330 poke is banned.
//
// Phase 1: MAP_BANK via remap_pfn_range(..., pgprot_writecombine).
// Phase 2: dmaengine memcpy CMA → bank (optional).
//
// Build requires MiSTer 5.15.1 kernel headers (not on device as of 2026-08-09).

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <asm/pgtable.h>
#include <asm/io.h>

#define MPLEX_DDR_NAME "mplex_ddr"
/* 720p dual-bank (2*0x180000) + bitstream ring/CTRL at 0x30300000.
 * Legacy 0x300000 ended exactly at DATA_PHYS so the ring fell on cached
 * /dev/mem and FPGA consumer never saw PLXB (STREAM1 cons=0). */
#define MPLEX_DDR_PHYS 0x30000000UL
#define MPLEX_DDR_SIZE 0x400000UL

static dev_t mplex_devt;
static struct class *mplex_class;
static struct cdev mplex_cdev;

static int mplex_open(struct inode *inode, struct file *file)
{
	return 0;
}

static int mplex_release(struct inode *inode, struct file *file)
{
	return 0;
}

static int mplex_mmap(struct file *file, struct vm_area_struct *vma)
{
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long pfn = MPLEX_DDR_PHYS >> PAGE_SHIFT;

	if (size > MPLEX_DDR_SIZE)
		return -EINVAL;
	if (vma->vm_pgoff != 0)
		return -EINVAL;

	/* Write-combine: CPU stores retire without cacheline RMW thrash on /dev/mem. */
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
	vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#else
	vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#endif
	if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot))
		return -EAGAIN;
	return 0;
}

static const struct file_operations mplex_fops = {
	.owner = THIS_MODULE,
	.open = mplex_open,
	.release = mplex_release,
	.mmap = mplex_mmap,
};

static int __init mplex_ddr_init(void)
{
	int ret;

	ret = alloc_chrdev_region(&mplex_devt, 0, 1, MPLEX_DDR_NAME);
	if (ret)
		return ret;
	cdev_init(&mplex_cdev, &mplex_fops);
	ret = cdev_add(&mplex_cdev, mplex_devt, 1);
	if (ret)
		goto err_cdev;
	mplex_class = class_create(THIS_MODULE, MPLEX_DDR_NAME);
	if (IS_ERR(mplex_class)) {
		ret = PTR_ERR(mplex_class);
		goto err_class;
	}
	if (IS_ERR(device_create(mplex_class, NULL, mplex_devt, NULL, MPLEX_DDR_NAME))) {
		ret = -EINVAL;
		goto err_dev;
	}
	pr_info("mplex_ddr: WC mmap phys=0x%lx size=0x%lx\n", MPLEX_DDR_PHYS, MPLEX_DDR_SIZE);
	return 0;
err_dev:
	class_destroy(mplex_class);
err_class:
	cdev_del(&mplex_cdev);
err_cdev:
	unregister_chrdev_region(mplex_devt, 1);
	return ret;
}

static void __exit mplex_ddr_exit(void)
{
	device_destroy(mplex_class, mplex_devt);
	class_destroy(mplex_class);
	cdev_del(&mplex_cdev);
	unregister_chrdev_region(mplex_devt, 1);
}

module_init(mplex_ddr_init);
module_exit(mplex_ddr_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("MiSTerPlex");
MODULE_DESCRIPTION("Write-combine DDR bank window for MiSTerPlex present");
