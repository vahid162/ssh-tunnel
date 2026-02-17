# SSH TUN + DNAT (نصب خیلی ساده)

.

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

## مقدارهای پیشنهادی برای مبتدی (روی ایران)

- `TUN ID`: `5`
- `IP تونل ایران`: `192.168.83.1`
- `IP تونل خارج`: `192.168.83.2`
- `Mask`: `30`
- `MTU`: `1240`
- `TCP ports`: مثل `443,2096`
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
