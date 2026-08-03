// misterplex_bank — skeleton dmaengine + WC bank map owner (w-path).
// NOT built by default. Parent/device kernel tree required.
// Design: docs/evidence/p720-path-20260803/KERNEL_DMA_AND_WC_DESIGN.md
//
// DO NOT unbind dma-pl330 from userspace. This module is a *client* of it.

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#define MPB_NAME "misterplex_bank"
#define MPB_API_VERSION 1
#define MPB_IOC_MAGIC 0xB7
#define MPB_IOC_INFO _IOWR(MPB_IOC_MAGIC, 0x01, struct mpb_info)
#define MPB_IOC_DMA_MEMCPY _IOW(MPB_IOC_MAGIC, 0x02, struct mpb_dma_req)
#define MPB_IOC_SET_MAP_PROT _IOW(MPB_IOC_MAGIC, 0x03, struct mpb_map_prot_req)

#define MPB_MAP_NONCACHED 0
#define MPB_MAP_WRITECOMBINE 1
#define MPB_MAP_CACHED_LAB 2

#define MPB_BANK0_PHYS 0x30000000u
#define MPB_BANK1_PHYS 0x30180000u
#define MPB_BANK_BYTES 0x00180000u

struct mpb_info {
	u32 api_version;
	u32 n_banks;
	u32 bank0_phys;
	u32 bank1_phys;
	u32 bank_bytes;
	u32 map_prot;
	u32 dma_capable;
	u32 reserved0;
};

struct mpb_dma_req {
	u32 src_phys;
	u32 dst_bank;
	u32 len;
	u32 flags; /* bit0 = sync */
};

struct mpb_map_prot_req {
	u32 prot;
	u32 reserved0;
};

struct mpb_dev {
	struct cdev cdev;
	dev_t devt;
	struct class *class;
	struct device *device;
	struct dma_chan *chan;
	u32 map_prot;
};

static struct mpb_dev *mpb;

static u32 mpb_bank_phys(u32 bank)
{
	return bank ? MPB_BANK1_PHYS : MPB_BANK0_PHYS;
}

static int mpb_open(struct inode *inode, struct file *file)
{
	file->private_data = mpb;
	return 0;
}

static int mpb_release(struct inode *inode, struct file *file)
{
	return 0;
}

static long mpb_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct mpb_dev *d = file->private_data;

	if (!d)
		return -ENODEV;

	if (cmd == MPB_IOC_INFO) {
		struct mpb_info info = {
			.api_version = MPB_API_VERSION,
			.n_banks = 2,
			.bank0_phys = MPB_BANK0_PHYS,
			.bank1_phys = MPB_BANK1_PHYS,
			.bank_bytes = MPB_BANK_BYTES,
			.map_prot = d->map_prot,
			.dma_capable = d->chan ? 1 : 0,
		};

		if (copy_to_user((void __user *)arg, &info, sizeof(info)))
			return -EFAULT;
		return 0;
	}

	if (cmd == MPB_IOC_SET_MAP_PROT) {
		struct mpb_map_prot_req req;

		if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
			return -EFAULT;
		if (req.prot > MPB_MAP_CACHED_LAB)
			return -EINVAL;
		/* Remap is process-local via mmap; store policy for next mmap. */
		d->map_prot = req.prot;
		return 0;
	}

	if (cmd == MPB_IOC_DMA_MEMCPY) {
		struct mpb_dma_req req;
		dma_addr_t dst;
		struct dma_async_tx_descriptor *tx;
		dma_cookie_t cookie;
		enum dma_status st;

		if (!d->chan)
			return -ENODEV;
		if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
			return -EFAULT;
		if (req.dst_bank > 1 || req.len == 0 || req.len > MPB_BANK_BYTES)
			return -EINVAL;
		if (req.src_phys == 0)
			return -EINVAL;

		dst = (dma_addr_t)mpb_bank_phys(req.dst_bank);
		/*
		 * NOTE: production must dma_map the src RAM buffer.
		 * Skeleton accepts phys for lab bring-up only — replace before ship.
		 */
		tx = dmaengine_prep_dma_memcpy(d->chan, dst, (dma_addr_t)req.src_phys,
					       req.len, DMA_CTRL_ACK | DMA_PREP_INTERRUPT);
		if (!tx)
			return -EIO;
		cookie = dmaengine_submit(tx);
		if (dma_submit_error(cookie))
			return -EIO;
		dma_async_issue_pending(d->chan);
		if (req.flags & 1u) {
			st = dma_sync_wait(d->chan, cookie);
			if (st != DMA_COMPLETE)
				return -EIO;
		}
		return 0;
	}

	return -ENOTTY;
}

static int mpb_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct mpb_dev *d = file->private_data;
	unsigned long size = vma->vm_end - vma->vm_start;
	unsigned long off = vma->vm_pgoff << PAGE_SHIFT;
	unsigned long pfn;
	u32 bank;

	if (!d)
		return -ENODEV;
	if (size > MPB_BANK_BYTES)
		return -EINVAL;
	if (off == 0)
		bank = 0;
	else if (off == MPB_BANK_BYTES)
		bank = 1;
	else
		return -EINVAL;

	pfn = mpb_bank_phys(bank) >> PAGE_SHIFT;

	if (d->map_prot == MPB_MAP_WRITECOMBINE)
		vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	else if (d->map_prot == MPB_MAP_CACHED_LAB)
		; /* leave default — lab only + explicit flush required */
	else
		vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);

	if (remap_pfn_range(vma, vma->vm_start, pfn, size, vma->vm_page_prot))
		return -EAGAIN;
	return 0;
}

static const struct file_operations mpb_fops = {
	.owner = THIS_MODULE,
	.open = mpb_open,
	.release = mpb_release,
	.unlocked_ioctl = mpb_ioctl,
	.mmap = mpb_mmap,
};

static int __init mpb_init(void)
{
	int ret;
	dma_cap_mask_t mask;

	mpb = kzalloc(sizeof(*mpb), GFP_KERNEL);
	if (!mpb)
		return -ENOMEM;
	mpb->map_prot = MPB_MAP_NONCACHED;

	dma_cap_zero(mask);
	dma_cap_set(DMA_MEMCPY, mask);
	mpb->chan = dma_request_channel(mask, NULL, NULL);
	if (!mpb->chan)
		pr_warn(MPB_NAME ": no MEMCPY dma channel (WC mmap still available)\n");

	ret = alloc_chrdev_region(&mpb->devt, 0, 1, MPB_NAME);
	if (ret)
		goto err_chan;
	cdev_init(&mpb->cdev, &mpb_fops);
	mpb->cdev.owner = THIS_MODULE;
	ret = cdev_add(&mpb->cdev, mpb->devt, 1);
	if (ret)
		goto err_region;
	mpb->class = class_create(THIS_MODULE, MPB_NAME);
	if (IS_ERR(mpb->class)) {
		ret = PTR_ERR(mpb->class);
		goto err_cdev;
	}
	mpb->device = device_create(mpb->class, NULL, mpb->devt, NULL, MPB_NAME);
	if (IS_ERR(mpb->device)) {
		ret = PTR_ERR(mpb->device);
		goto err_class;
	}

	pr_info(MPB_NAME ": ready api=%u dma=%d (never unbind pdma)\n", MPB_API_VERSION,
		mpb->chan ? 1 : 0);
	return 0;

err_class:
	class_destroy(mpb->class);
err_cdev:
	cdev_del(&mpb->cdev);
err_region:
	unregister_chrdev_region(mpb->devt, 1);
err_chan:
	if (mpb->chan)
		dma_release_channel(mpb->chan);
	kfree(mpb);
	mpb = NULL;
	return ret;
}

static void __exit mpb_exit(void)
{
	if (!mpb)
		return;
	device_destroy(mpb->class, mpb->devt);
	class_destroy(mpb->class);
	cdev_del(&mpb->cdev);
	unregister_chrdev_region(mpb->devt, 1);
	if (mpb->chan)
		dma_release_channel(mpb->chan);
	kfree(mpb);
	mpb = NULL;
}

module_init(mpb_init);
module_exit(mpb_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("MiSTerPlex w-path");
MODULE_DESCRIPTION("Frame-bank WC map + dmaengine client (do not unbind pl330)");
