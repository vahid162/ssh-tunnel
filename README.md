# SSH TUN + DNAT

این ریپو یک اسکریپت نصب/کانفیگ برای سناریوی زیر می‌دهد:

- ساخت لینک لایه ۳ بین دو سرور با `ssh -w` (اینترفیس `tun`)
- DNAT کردن پورت‌های ورودی روی سرور ایران به سمت IP تونلِ سرور خارج
- پایدارسازی با `systemd`

## سناریو

- `iran`: ورودی کاربران
- `khrej`: محل اجرای سرویس اصلی
- مثال:
  - `iran tun5 = 192.168.83.1/30`
  - `khrej tun5 = 192.168.83.2/30`
  - کاربران به `iran:2096` وصل می‌شوند و ترافیک روی تونل به `khrej:2096` می‌رسد.

---

## اجرا

> اسکریپت باید با `root` اجرا شود.

### روش مستقیم از GitHub (بعد از تعیین URL درست)

> **مهم:** در حال حاضر ممکن است URL ثابت 404 بدهد اگر ریپو private باشد یا نام owner/repo اشتباه باشد.
> قبل از اجرا، آدرس raw واقعی را با دستور زیر پیدا/تست کن.

```bash
# 1) URL را با owner/repo/branch واقعی خودت بساز
RAW_URL="https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh"

# 2) باید 200 برگرداند
curl -I "$RAW_URL" | head -n 1

# 3) بعد اجرا کن
bash <(curl -fsSL "$RAW_URL")
```

یک بار روی `khrej` اجرا کن (Role = `khrej`) و یک بار روی `iran` (Role = `iran`).

### اجرای بدون سؤال Role

```bash
RAW_URL="https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh"
ROLE=khrej bash <(curl -fsSL "$RAW_URL")
ROLE=iran  bash <(curl -fsSL "$RAW_URL")
```

### روش جایگزین (بدون raw URL)

اگر ریپو private است یا raw در دسترس نیست، روی سرور مقصد فایل را مستقیم کپی و اجرا کن:

```bash
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/
ssh root@<SERVER_IP> 'bash /root/ssh-tun-dnat.sh'
```

> اگر این URL روی سرور شما `404` داد، یعنی این ریپو/branch از بیرون قابل دسترس نیست (مثلاً private یا هنوز push نشده) و باید از روش جایگزین پایین استفاده کنید.

### روش جایگزین (بدون raw URL)

اگر ریپو private است یا raw در دسترس نیست، روی سرور مقصد فایل را مستقیم کپی و اجرا کن:

```bash
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/
ssh root@<SERVER_IP> 'bash /root/ssh-tun-dnat.sh'
```

---

## اسکریپت چه کار می‌کند؟

## 1) وقتی Role = khrej

- نصب ابزارهای لازم (`openssh-server`, `iproute2`, `iptables`)
- بررسی/فعال‌سازی `tun` (`/dev/net/tun` + `modprobe tun`)
- تنظیم `sshd_config`:
  - `PermitTunnel yes`
  - `AllowTcpForwarding yes`
- تست و ری‌استارت سرویس SSH

## 2) وقتی Role = iran

- گرفتن اطلاعات تونل و پورت‌ها به‌صورت interactive
- بررسی دسترسی SSH بدون پسورد به `khrej`
- ساخت سرویس `systemd` برای نگه‌داشتن تونل با `ssh -w TUN:TUN -N`
- اجرای setup بعد از بالا آمدن تونل:
  - ست کردن IP/MTU روی دو طرف
  - فعال‌سازی `net.ipv4.ip_forward=1` روی `iran`
  - DNAT در `PREROUTING`
  - `MASQUERADE` در `POSTROUTING` روی خروجی `tun`
  - (اختیاری) باز کردن فایروال روی `khrej` برای پورت‌ها روی `tun`
  - (اختیاری) MSS clamp برای مسیرهای MTU محدود
- بعد از فعال‌سازی سرویس، به‌صورت خودکار سلامت تونل را چک می‌کند (وجود `tunX` روی هر دو سمت + تست ping best-effort)

---

## نکات مهم

- اگر اتصال‌های TCP (مثلاً TLS/WS) گیر می‌کنند:
  - MTU پایین‌تر (مثلاً `1240`) انتخاب کن.
  - MSS clamp را فعال کن.
- روی بعضی سیستم‌ها backend فایروال `nft` است و دستور `iptables` از لایه سازگاری استفاده می‌کند.
- اگر policy زنجیره‌های فایروال روی `DROP` باشد، قوانین اضافی ممکن است لازم شود (مثل allow برای `ESTABLISHED,RELATED`).

---

## عیب‌یابی سریع

### روی iran

```bash
ip a show tun5
systemctl status ssh-tun5-dnat.service --no-pager
iptables -t nat -vnL PREROUTING
iptables -vnL FORWARD
```

### روی khrej

```bash
ip a show tun5
ss -lntup | grep 2096
```

---

## مسیر فایل‌های ساخته‌شده توسط اسکریپت

- env:
  - `/etc/ssh-tun-dnat/tunX.env`
- setup script:
  - `/usr/local/sbin/ssh-tun-dnat-setup.sh`
- service:
  - `/etc/systemd/system/ssh-tunX-dnat.service`
