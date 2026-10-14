// SPDX-License-Identifier: GPL-2.0
/*
 * Bring-up diagnostic, not a driver: power up the HP Pro x2 612 G2 front
 * camera (ACPI INT347F, believed Sony IMX241) with the sequence recovered
 * from the Windows driver, dump its identification registers, power down.
 *
 * Sequence (Windows CrdG2 "VoltageUF" with CLDB[14] = 0): analog enable
 * (GPIO4) first, then I/O (VAUX2, "vio"), then core (VAUX1, "vcore"),
 * optionally the VCM supply (GPIO3), clock on, reset/powerdown (GPIO5/6)
 * released, 20 ms delay, then I2C access.
 *
 * The probe always fails with -ENODEV after the dump so nothing stays bound
 * or powered.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/regulator/consumer.h>

static bool use_vcm;
module_param(use_vcm, bool, 0444);
MODULE_PARM_DESC(use_vcm, "also enable the VCM supply (GPIO3)");

static unsigned int clk_hz = 19200000;
module_param(clk_hz, uint, 0444);
MODULE_PARM_DESC(clk_hz, "sensor clock rate (default 19.2 MHz, per SSDB)");

static unsigned int hold_s;
module_param(hold_s, uint, 0444);
MODULE_PARM_DESC(hold_s, "keep the sensor powered this long after the dump (s)");

/* Addresses to try: ACPI first, then common Sony / CCS addresses. */
static const u16 addrs[] = { 0, 0x10, 0x1a, 0x36 };

static int read_regs(struct i2c_adapter *adap, u16 addr, u16 reg, u8 *buf,
		     u16 len)
{
	u8 wbuf[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[] = {
		{ .addr = addr, .flags = 0, .len = 2, .buf = wbuf },
		{ .addr = addr, .flags = I2C_M_RD, .len = len, .buf = buf },
	};
	int ret = i2c_transfer(adap, msgs, ARRAY_SIZE(msgs));

	return ret == ARRAY_SIZE(msgs) ? 0 : (ret < 0 ? ret : -EIO);
}

static void dump(struct i2c_client *client, u16 addr)
{
	struct device *dev = &client->dev;
	u8 buf[16];
	int ret;

	ret = read_regs(client->adapter, addr, 0x0000, buf, 16);
	if (ret) {
		dev_info(dev, "0x%02x: no answer (%d)\n", addr, ret);
		return;
	}
	dev_info(dev, "0x%02x: regs 0x0000: %*ph\n", addr, 16, buf);

	if (!read_regs(client->adapter, addr, 0x0010, buf, 16))
		dev_info(dev, "0x%02x: regs 0x0010: %*ph\n", addr, 16, buf);
	if (!read_regs(client->adapter, addr, 0x0100, buf, 4))
		dev_info(dev, "0x%02x: regs 0x0100: %*ph\n", addr, 4, buf);
}

static int imx241_probe_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct gpio_desc *avdd, *vcm, *reset, *pwdn;
	struct regulator *vio, *vcore;
	struct clk *clk;
	unsigned int i;
	int ret;

	avdd = devm_gpiod_get(dev, "avdd-enable", GPIOD_OUT_LOW);
	if (IS_ERR(avdd))
		return dev_err_probe(dev, PTR_ERR(avdd), "avdd-enable gpio\n");
	vcm = devm_gpiod_get(dev, "vcm-enable", GPIOD_OUT_LOW);
	if (IS_ERR(vcm))
		return dev_err_probe(dev, PTR_ERR(vcm), "vcm-enable gpio\n");
	reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(reset))
		return dev_err_probe(dev, PTR_ERR(reset), "reset gpio\n");
	pwdn = devm_gpiod_get(dev, "powerdown", GPIOD_OUT_HIGH);
	if (IS_ERR(pwdn))
		return dev_err_probe(dev, PTR_ERR(pwdn), "powerdown gpio\n");

	vio = devm_regulator_get(dev, "vio");
	if (IS_ERR(vio))
		return dev_err_probe(dev, PTR_ERR(vio), "vio\n");
	vcore = devm_regulator_get(dev, "vcore");
	if (IS_ERR(vcore))
		return dev_err_probe(dev, PTR_ERR(vcore), "vcore\n");

	clk = devm_clk_get(dev, NULL);
	if (IS_ERR(clk))
		return dev_err_probe(dev, PTR_ERR(clk), "clock\n");

	dev_info(dev, "powering up (adapter %s, ACPI address 0x%02x)\n",
		 dev_name(&client->adapter->dev), client->addr);

	gpiod_set_value_cansleep(avdd, 1);
	usleep_range(1000, 2000);

	ret = regulator_enable(vio);
	if (ret) {
		dev_err(dev, "enabling vio: %d\n", ret);
		goto off_avdd;
	}
	ret = regulator_enable(vcore);
	if (ret) {
		dev_err(dev, "enabling vcore: %d\n", ret);
		goto off_vio;
	}
	if (use_vcm)
		gpiod_set_value_cansleep(vcm, 1);

	ret = clk_set_rate(clk, clk_hz);
	if (ret)
		dev_warn(dev, "setting clock to %u Hz: %d\n", clk_hz, ret);
	ret = clk_prepare_enable(clk);
	if (ret) {
		dev_err(dev, "enabling clock: %d\n", ret);
		goto off_vcore;
	}
	dev_info(dev, "rails on (vio %d uV, vcore %d uV), clock %lu Hz\n",
		 regulator_get_voltage(vio), regulator_get_voltage(vcore),
		 clk_get_rate(clk));

	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(reset, 0);
	gpiod_set_value_cansleep(pwdn, 0);
	msleep(20);

	for (i = 0; i < ARRAY_SIZE(addrs); i++)
		dump(client, addrs[i] ? addrs[i] : client->addr);

	if (hold_s) {
		dev_info(dev, "holding power for %u s\n", hold_s);
		msleep(hold_s * 1000);
	}

	gpiod_set_value_cansleep(pwdn, 1);
	gpiod_set_value_cansleep(reset, 1);
	clk_disable_unprepare(clk);
off_vcore:
	gpiod_set_value_cansleep(vcm, 0);
	regulator_disable(vcore);
off_vio:
	regulator_disable(vio);
off_avdd:
	gpiod_set_value_cansleep(avdd, 0);
	dev_info(dev, "powered down\n");

	return -ENODEV;
}

static const struct acpi_device_id imx241_probe_acpi_ids[] = {
	{ "INT347F" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, imx241_probe_acpi_ids);

static struct i2c_driver imx241_probe_driver = {
	.driver = {
		.name = "imx241_probe",
		.acpi_match_table = imx241_probe_acpi_ids,
	},
	.probe = imx241_probe_probe,
};
module_i2c_driver(imx241_probe_driver);

MODULE_DESCRIPTION("HP Pro x2 612 G2 front camera bring-up probe (diagnostic)");
MODULE_LICENSE("GPL");
