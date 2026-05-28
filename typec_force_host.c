#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/extcon.h>
#include <linux/extcon-provider.h>
#include <linux/regulator/consumer.h>
#include <linux/delay.h>

static struct extcon_dev *typec_extcon;
static struct regulator *vbus_reg;
static struct kobject *typec_kobj;

static int force_host_mode(bool enable)
{
	int ret;

	if (!typec_extcon) {
		typec_extcon = extcon_get_extcon_dev("typec-extcon");
		if (!typec_extcon) {
			pr_err("typec_force_host: failed to find typec-extcon\n");
			return -ENODEV;
		}
	}

	if (!vbus_reg) {
		vbus_reg = regulator_get(NULL, "vbus_5vout");
		if (IS_ERR(vbus_reg)) {
			pr_err("typec_force_host: failed to get vbus_5vout regulator: %ld\n",
			       PTR_ERR(vbus_reg));
			vbus_reg = NULL;
			return PTR_ERR(vbus_reg);
		}
	}

	if (enable) {
		pr_info("typec_force_host: enabling host mode\n");

		ret = regulator_enable(vbus_reg);
		if (ret) {
			pr_err("typec_force_host: failed to enable vbus regulator: %d\n", ret);
			return ret;
		}

		msleep(100);

		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, true);
		if (ret) {
			pr_err("typec_force_host: failed to set EXTCON_USB_HOST: %d\n", ret);
			regulator_disable(vbus_reg);
			return ret;
		}

		pr_info("typec_force_host: host mode enabled\n");
	} else {
		pr_info("typec_force_host: disabling host mode\n");

		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, false);
		if (ret)
			pr_warn("typec_force_host: failed to clear EXTCON_USB_HOST: %d\n", ret);

		if (vbus_reg && regulator_is_enabled(vbus_reg)) {
			ret = regulator_disable(vbus_reg);
			if (ret)
				pr_warn("typec_force_host: failed to disable vbus: %d\n", ret);
		}

		pr_info("typec_force_host: host mode disabled\n");
	}

	return 0;
}

static ssize_t force_host_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "Write 1 to force host mode, 0 to disable\n");
}

static ssize_t force_host_store(struct kobject *kobj,
				struct kobj_attribute *attr,
				const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 0, &val);
	if (ret)
		return ret;

	ret = force_host_mode(val ? true : false);
	if (ret)
		return ret;

	return count;
}

static struct kobj_attribute force_host_attr = __ATTR_RW(force_host);

static struct attribute *attrs[] = {
	&force_host_attr.attr,
	NULL,
};

static struct attribute_group attr_group = {
	.attrs = attrs,
};

static int __init typec_force_host_init(void)
{
	int ret;

	typec_extcon = extcon_get_extcon_dev("typec-extcon");
	if (!typec_extcon)
		pr_warn("typec_force_host: typec-extcon not available yet, will retry on write\n");

	vbus_reg = regulator_get(NULL, "vbus_5vout");
	if (IS_ERR(vbus_reg)) {
		pr_warn("typec_force_host: vbus_5vout unavailable: %ld\n", PTR_ERR(vbus_reg));
		vbus_reg = NULL;
	}

	typec_kobj = kobject_create_and_add("typec_force_host", kernel_kobj);
	if (!typec_kobj) {
		pr_err("typec_force_host: failed to create sysfs entry\n");
		ret = -ENOMEM;
		goto err_reg;
	}

	ret = sysfs_create_group(typec_kobj, &attr_group);
	if (ret) {
		pr_err("typec_force_host: failed to create sysfs group: %d\n", ret);
		kobject_put(typec_kobj);
		goto err_reg;
	}

	pr_info("typec_force_host: loaded. Use: echo 1 > /sys/kernel/typec_force_host/force_host\n");
	return 0;

err_reg:
	if (vbus_reg)
		regulator_put(vbus_reg);
	return ret;
}

static void __exit typec_force_host_exit(void)
{
	if (vbus_reg)
		regulator_put(vbus_reg);
	sysfs_remove_group(typec_kobj, &attr_group);
	kobject_put(typec_kobj);

	if (typec_extcon)
		extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, false);

	pr_info("typec_force_host: unloaded\n");
}

module_init(typec_force_host_init);
module_exit(typec_force_host_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Force host mode on Pinebook Pro USB-C port via extcon");
MODULE_AUTHOR("opencode");
