#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/device.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/extcon.h>
#include <linux/extcon-provider.h>
#include <linux/of_gpio.h>

static struct extcon_dev *typec_extcon;
static struct kobject *typec_kobj;
static bool force_host_active;
static bool force_data_host_active;
static int vbus_gpio = -1;

static void set_vbus_gpio(int value)
{
	if (gpio_is_valid(vbus_gpio)) {
		gpio_set_value(vbus_gpio, value);
		pr_info("typec_force_host: vbus_gpio=%d value=%d (readback=%d)\n",
			vbus_gpio, value, gpio_get_value(vbus_gpio));
	}
}

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

	if (enable) {
		pr_info("typec_force_host: enabling host mode\n");

		set_vbus_gpio(1);

		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, true);
		if (ret) {
			pr_err("typec_force_host: failed to set EXTCON_USB_HOST: %d\n", ret);
			set_vbus_gpio(0);
			return ret;
		}

		force_host_active = true;
	} else {
		pr_info("typec_force_host: disabling host mode\n");

		set_vbus_gpio(0);

		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, false);
		if (ret)
			pr_warn("typec_force_host: failed to clear EXTCON_USB_HOST: %d\n", ret);

		force_host_active = false;
		force_data_host_active = false;
	}

	return 0;
}

static int force_data_host_mode(bool enable)
{
	int ret;

	if (!typec_extcon) {
		typec_extcon = extcon_get_extcon_dev("typec-extcon");
		if (!typec_extcon) {
			pr_err("typec_force_host: failed to find typec-extcon\n");
			return -ENODEV;
		}
	}

	if (enable) {
		pr_info("typec_force_host: enabling data host mode (no VBUS)\n");
		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, true);
		if (ret) {
			pr_err("typec_force_host: failed to set EXTCON_USB_HOST: %d\n", ret);
			return ret;
		}
		force_data_host_active = true;
	} else {
		pr_info("typec_force_host: disabling data host mode\n");
		ret = extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, false);
		if (ret)
			pr_warn("typec_force_host: failed to clear EXTCON_USB_HOST: %d\n", ret);
		force_data_host_active = false;
		force_host_active = false;
	}

	return 0;
}

static ssize_t force_host_show(struct kobject *kobj,
			       struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", force_host_active ? 1 : 0);
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

static ssize_t force_data_host_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", force_data_host_active ? 1 : 0);
}

static ssize_t force_data_host_store(struct kobject *kobj,
				     struct kobj_attribute *attr,
				     const char *buf, size_t count)
{
	int val, ret;

	ret = kstrtoint(buf, 0, &val);
	if (ret)
		return ret;

	ret = force_data_host_mode(val ? true : false);
	if (ret)
		return ret;

	return count;
}

static struct kobj_attribute force_data_host_attr = __ATTR_RW(force_data_host);

static struct attribute *attrs[] = {
	&force_host_attr.attr,
	&force_data_host_attr.attr,
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

	typec_kobj = kobject_create_and_add("typec_force_host", kernel_kobj);
	if (!typec_kobj) {
		pr_err("typec_force_host: failed to create sysfs entry\n");
		return -ENOMEM;
	}

	ret = sysfs_create_group(typec_kobj, &attr_group);
	if (ret) {
		pr_err("typec_force_host: failed to create sysfs group: %d\n", ret);
		kobject_put(typec_kobj);
		return ret;
	}

	/* Look up VBUS GPIO from vbus_5vout regulator DT node */
	{
		struct device_node *np;
		for_each_compatible_node(np, NULL, "regulator-fixed") {
			const char *name;
			if (of_property_read_string(np, "regulator-name", &name) == 0 &&
			    strcmp(name, "vbus_5vout") == 0) {
				int gpio = of_get_named_gpio(np, "gpio", 0);
				if (gpio_is_valid(gpio)) {
					vbus_gpio = gpio;
					pr_info("typec_force_host: found vbus GPIO %d\n", gpio);
				}
				of_node_put(np);
				break;
			}
		}
	}

	pr_info("typec_force_host: loaded.\n");
	return 0;
}

static void __exit typec_force_host_exit(void)
{
	sysfs_remove_group(typec_kobj, &attr_group);
	kobject_put(typec_kobj);

	if (typec_extcon)
		extcon_set_state_sync(typec_extcon, EXTCON_USB_HOST, false);

	set_vbus_gpio(0);

	pr_info("typec_force_host: unloaded\n");
}

module_init(typec_force_host_init);
module_exit(typec_force_host_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Force host mode on Pinebook Pro USB-C port via extcon");
MODULE_AUTHOR("opencode");
