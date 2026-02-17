# SSH TUN + DNAT (نصب خیلی ساده)

این پروژه برای تانل **ایران → خارج** است.

هدف: با **یک دستور** روی هر سرور اجرا کنی، اسکریپت خودش سؤال‌ها را بپرسد و تنظیمات را انجام دهد.

---

## کاری که باید انجام بدهی (خیلی خلاصه)

فقط 2 کار:

1) روی سرور خارج این یک دستور را بزن.
2) روی سرور ایران این یک دستور را بزن.

> ترتیب مهم است: **اول خارج، بعد ایران**.

---

## دستور یک‌خطی روی سرور خارج

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh)
```

بعد از اجرا، وقتی پرسید Role، مقدار زیر را بده:

```text
khrej
```

اسکریپت خودش:
- پکیج‌ها را نصب می‌کند.
- `PermitTunnel yes` را در SSH فعال می‌کند.

---

## دستور یک‌خطی روی سرور ایران

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/ssh-tun-dnat.sh)
```

بعد از اجرا، وقتی پرسید Role، مقدار زیر را بده:

```text
iran
```

اسکریپت بقیه سؤال‌ها را مرحله‌به‌مرحله می‌پرسد (IP خارج، پورت SSH، TUN ID، پورت‌های فوروارد و ...).

---

## اگر raw لینک کار نکرد (404 / private)

اگر لینک GitHub raw در دسترس نبود، همین روش جایگزین را استفاده کن:

```bash
# روی سیستم خودت
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/

# روی همان سرور
ssh root@<SERVER_IP> 'bash /root/ssh-tun-dnat.sh'
```

برای خارج Role=`khrej` و برای ایران Role=`iran`.

---

## پیشنهاد مقدارها برای کاربر مبتدی (روی ایران)

- `TUN ID`: `5`
- `IP تونل ایران`: `192.168.83.1`
- `IP تونل خارج`: `192.168.83.2`
- `Mask`: `30`
- `MTU`: `1240`
- `TCP ports`: مثلاً `443,2096`
- `MSS clamp`: `y`

اگر نمی‌دانی چه بزنی، فعلاً پیش‌فرض‌ها را نگه دار.

---

## چک نهایی (بعد از نصب)

### روی ایران

```bash
ip a show tun5
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 100 --no-pager
iptables -t nat -vnL PREROUTING
```

### روی خارج

```bash
ip a show tun5
ss -lntup
```

اگر `tun5` نداری، عدد `5` را با `TUN ID` خودت عوض کن.

---

## اگر مشکل داشتی، این خروجی‌ها را بفرست

### از ایران

```bash
ip a
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 200 --no-pager
iptables -t nat -vnL
iptables -vnL FORWARD
```

### از خارج

```bash
ip a
ss -lntup
cat /etc/ssh/sshd_config | sed -n '1,220p'
```

من بر اساس همین خروجی‌ها دقیق قدم‌به‌قدم می‌گم کجا مشکل است.
