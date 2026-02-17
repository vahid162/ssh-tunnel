# SSH TUN + DNAT (Iran ➜ Kharej)

این پروژه یک اسکریپت آماده می‌دهد که با **حداقل دستور**، یک تونل `ssh -w` بین سرور ایران و خارج می‌سازد و سپس پورت‌های ورودی ایران را با DNAT به سمت سرور خارج می‌فرستد.

هدف README این است که اگر مبتدی هستی، فقط همین مراحل را به‌ترتیب اجرا کنی و کار تمام شود.

---

## ایده‌ی کلی (خیلی ساده)

- کاربرها به `IP سرور ایران` روی یک پورت (مثلاً `2096`) وصل می‌شوند.
- روی سرور ایران، ترافیک همان پورت با DNAT می‌رود داخل تونل.
- داخل تونل، ترافیک به `IP تونل سرور خارج` می‌رسد.
- سرویس اصلی روی سرور خارج پاسخ می‌دهد.

نمونه:

- `iran tun5 = 192.168.83.1/30`
- `kharej tun5 = 192.168.83.2/30`
- `client -> iran:2096`  سپس  `DNAT -> 192.168.83.2:2096`

---

## پیش‌نیازها

1. دو سرور لینوکسی با دسترسی `root`:
   - سرور ایران (ورودی کاربران)
   - سرور خارج (محل سرویس اصلی)
2. ارتباط SSH از ایران به خارج برقرار باشد (پورت SSH خارج باز باشد).
3. سرویس مقصد روی خارج نصب/اجرا شده باشد (روی همان پورت‌هایی که می‌خواهی فوروارد کنی).
4. ماژول `tun` در کرنل قابل استفاده باشد (اسکریپت خودش بررسی/فعال‌سازی می‌کند).

---

## اجرای سریع (پیشنهادی)

> اسکریپت را **یک بار روی خارج** و **یک بار روی ایران** اجرا می‌کنی.

### گام 1) اجرای اسکریپت روی سرور خارج (Role=khrej)

روی سرور خارج:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh -o ssh-tun-dnat.sh
chmod +x ssh-tun-dnat.sh
ROLE=khrej bash ssh-tun-dnat.sh
```

این مرحله:
- SSH server و ابزار شبکه را نصب می‌کند.
- `PermitTunnel yes` و `AllowTcpForwarding yes` را در `sshd_config` تنظیم می‌کند.

### گام 2) اجرای اسکریپت روی سرور ایران (Role=iran)

روی سرور ایران:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh -o ssh-tun-dnat.sh
chmod +x ssh-tun-dnat.sh
ROLE=iran bash ssh-tun-dnat.sh
```

بعد از اجرا، اسکریپت از تو چند مقدار می‌پرسد (IP/Port/TUN/MTU/Ports...).
برای شروع امن، همان پیش‌فرض‌ها خوب هستند مگر اینکه شبکه‌ات خاص باشد.

---

## اگر raw GitHub نداشتی (private repo یا 404)

اگر `curl` خطای 404 داد، فایل را مستقیم کپی کن:

```bash
# روی سیستم خودت (جایی که فایل هست)
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/

# روی همان سرور
ssh root@<SERVER_IP> 'chmod +x /root/ssh-tun-dnat.sh && bash /root/ssh-tun-dnat.sh'
```

برای خارج مقدار `ROLE=khrej` و برای ایران `ROLE=iran` بگذار.

---

## مقادیر مهم هنگام اجرای Role=iran

اسکریپت سؤال می‌پرسد؛ این‌ها مهم‌ترین‌ها هستند:

- `IP/Domain سرور khrej`: آی‌پی یا دامنه سرور خارج
- `SSH user`: معمولاً `root`
- `SSH port`: معمولاً `22`
- `TUN ID`: مثلاً `5` (این یعنی اینترفیس `tun5`)
- `IP تونل روی iran`: پیش‌فرض `192.168.83.1`
- `IP تونل روی khrej`: پیش‌فرض `192.168.83.2`
- `Mask`: پیش‌فرض `30`
- `MTU`: پیش‌فرض `1240` (برای مسیرهای مشکل‌دار مقدار خوبی است)
- `TCP ports`: پورت‌هایی که باید فوروارد شوند (مثلاً `443,2096`)
- `UDP ports`: اگر لازم داری (در غیر این صورت خالی)
- `WAN interface`: معمولاً auto-detect می‌شود (مثل `eth0`)

پرسش‌های پیشنهادی:
- `MSS clamp`: بهتر است `y` بماند.
- `باز کردن INPUT روی khrej`: اگر فایروال داری معمولاً `y` بهتر است.

---

## این اسکریپت دقیقاً چه می‌سازد؟

### روی خارج (`khrej`)

- نصب پکیج‌های لازم (`openssh-server`, `iproute2`, `iptables`)
- تنظیم `sshd_config`:
  - `PermitTunnel yes`
  - `AllowTcpForwarding yes`
- ری‌استارت SSH

### روی ایران (`iran`)

- بررسی دسترسی SSH Key-based به خارج
- ساخت فایل env:
  - `/etc/ssh-tun-dnat/tunX.env`
- ساخت اسکریپت setup:
  - `/usr/local/sbin/ssh-tun-dnat-setup.sh`
- ساخت سرویس systemd:
  - `/etc/systemd/system/ssh-tunX-dnat.service`
- بالا آوردن تونل `ssh -w X:X -N`
- اعمال قوانین:
  - `DNAT` در `PREROUTING`
  - `MASQUERADE` در `POSTROUTING`
  - `FORWARD` لازم برای عبور ترافیک
  - در صورت نیاز `TCPMSS --clamp-mss-to-pmtu`

---

## دستورات بررسی سلامت (حتماً بعد از نصب)

### روی ایران

```bash
ip a show tun5
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 100 --no-pager
iptables -t nat -vnL PREROUTING
iptables -t nat -vnL POSTROUTING
iptables -vnL FORWARD
```

### روی خارج

```bash
ip a show tun5
ss -lntup
```

> اگر `tun5` نیست، `TUN ID` را مطابق انتخاب خودت جایگزین کن.

---

## عیب‌یابی سریع

### 1) سرویس روی ایران بالا نمی‌آید

```bash
systemctl restart ssh-tun5-dnat.service
journalctl -u ssh-tun5-dnat.service -n 200 --no-pager
```

علت‌های رایج:
- SSH key هنوز درست تنظیم نشده
- روی خارج `PermitTunnel` فعال نیست
- پورت SSH یا IP خارج اشتباه است

### 2) تونل بالا هست ولی ترافیک عبور نمی‌کند

- مطمئن شو سرویس مقصد روی خارج واقعاً روی همان پورت گوش می‌دهد.
- `WAN_IF` را درست انتخاب کرده باشی.
- اگر TLS/WS گیر می‌کند:
  - MTU را کمتر کن (مثلاً `1240` یا `1200`)
  - MSS clamp را فعال کن

### 3) ریبوت باعث قطع تونل می‌شود

سرویس systemd ساخته شده و باید خودکار بالا بیاید. چک کن:

```bash
systemctl is-enabled ssh-tun5-dnat.service
systemctl status ssh-tun5-dnat.service --no-pager
```

---

## نکات امنیتی مهم

- فقط وقتی مطمئنی دسترسی کلیدی داری، `PasswordAuthentication` را روی خارج غیرفعال کن.
- پورت SSH را در اینترنت عمومی تا حد ممکن محدود کن (Allowlist / Firewall).
- قوانین فایروال را دقیق و حداقلی نگه دار (فقط پورت‌های لازم).

---

## چک‌لیست نهایی (برای «فقط اجرا کنم و تمام») ✅

1. روی خارج: `ROLE=khrej` اجرا شد.
2. روی ایران: `ROLE=iran` اجرا شد.
3. `tunX` روی هر دو سرور بالا آمد.
4. سرویس `ssh-tunX-dnat.service` روی ایران active است.
5. شمارنده‌های iptables روی ایران با ترافیک واقعی زیاد می‌شوند.

اگر هرکدام fail بود، خروجی این‌ها را بفرست تا دقیق راهنمایی کنم:

```bash
# روی ایران
ip a
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 200 --no-pager
iptables -t nat -vnL
iptables -vnL FORWARD

# روی خارج
ip a
ss -lntup
cat /etc/ssh/sshd_config | sed -n '1,220p'
```
