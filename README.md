# SSH TUN + DNAT (نصب خیلی ساده)

این پروژه برای تانل **ایران → خارج** است.

هدف: فقط با **کپی/پیست دستور** روی هر سرور، همه چیز خودکار انجام شود.

---

## اجرای سریع (فقط کپی/پیست)

> ترتیب مهم: **اول سرور خارج، بعد سرور ایران**

### 1) روی سرور خارج (Kharej) این را اجرا کن

```bash
ROLE=khrej bash <(curl -fsSL https://raw.githubusercontent.com/vahid162/ssh-tunnel/main/ssh-tun-dnat.sh)
```

### 2) روی سرور ایران (Iran) این را اجرا کن

```bash
ROLE=iran bash <(curl -fsSL https://raw.githubusercontent.com/vahid162/ssh-tunnel/main/ssh-tun-dnat.sh)
```

در مرحله ایران، اسکریپت خودش سؤال‌ها را می‌پرسد (IP خارج، پورت SSH، TUN ID، پورت‌ها و ...).

---


## مدیریت بعد از نصب (خیلی مهم)

اگر یک‌بار نصب انجام شده، می‌تونی **همان اسکریپت** را دوباره اجرا کنی تا تنظیمات قبلی را مدیریت/تغییر بدهی:

```bash
ROLE=iran bash <(curl -fsSL https://raw.githubusercontent.com/vahid162/ssh-tunnel/main/ssh-tun-dnat.sh)
```

وقتی پروفایل قبلی پیدا شود، منوی مدیریت می‌بینی و می‌توانی این کارها را انجام بدهی:

- نمایش تنظیمات فعلی
- Restart / Stop / Start سرویس
- اجرای مجدد setup برای اعمال دوباره iptables/tun
- ویرایش کامل تنظیمات (IP ها، پورت‌ها، MTU، MSS، فایروال و ...)
- حذف پروفایل و سرویس

> اگر در ویرایش، `TUN ID` را عوض کنی، سرویس/پروفایل قبلی خودکار جمع می‌شود و سرویس جدید ساخته می‌شود.

---

## مقدارهای پیشنهادی برای مبتدی (روی ایران)

- `TUN ID`: `5`
- `IP تونل ایران`: `192.168.83.1`
- `IP تونل خارج`: `192.168.83.2`
- `Mask`: `30`
- `MTU`: `1240`
- `TCP ports`: می‌تونی 1 تا هرچندتا بدی، مثل `2096` یا `443,2096` یا بازه `20000-20010`
- `UDP ports`: اگر خواستی مثل TCP (تکی/چندتا/بازه) وارد کن؛ اگر نمی‌خوای خالی بگذار
- `MSS clamp`: `y`

اگر مطمئن نیستی، پیش‌فرض‌ها را تغییر نده.

---

## اگر لینک raw در دسترس نبود (خیلی نادر)

```bash
# روی سیستم خودت
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/

# روی همان سرور
ssh root@<SERVER_IP> 'ROLE=khrej bash /root/ssh-tun-dnat.sh'
ssh root@<SERVER_IP> 'ROLE=iran  bash /root/ssh-tun-dnat.sh'
```

---

## چک نهایی بعد از نصب

### روی ایران

```bash
ip a show tun5
systemctl status ssh-tun5-dnat.service --no-pager
iptables -t nat -vnL PREROUTING
```

### روی خارج

```bash
ip a show tun5
ss -lntup
```

> اگر `tun5` نیست، عدد 5 را با `TUN ID` خودت عوض کن.

---

## اگر مشکل داشتی این خروجی‌ها را بفرست

### ایران

```bash
ip a
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 200 --no-pager
iptables -t nat -vnL
iptables -vnL FORWARD
```

### خارج

```bash
ip a
ss -lntup
cat /etc/ssh/sshd_config | sed -n '1,220p'
```

من با همین خروجی‌ها دقیق و قدم‌به‌قدم مشکل را پیدا می‌کنم.
