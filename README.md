# ssh-tunnel

نحوه‌ی استفاده مثل مثال خودت (curl|bash)

بعد از اینکه اسکریپت رو تو GitHub گذاشتی، روی هر سرور اینو می‌زنی:

bash <(curl -fsSL "https://raw.githubusercontent.com/<USER>/<REPO>/main/ssh-tun-dnat.sh")


یک‌بار روی khrej اجرا کن و وقتی پرسید Role، بگو: khrej

یک‌بار روی iran اجرا کن و Role را iran بزن (سؤال‌ها را جواب بده)

اگر بخوای بدون سؤال Role مشخص باشه:

ROLE=khrej bash <(curl -fsSL "https://raw.githubusercontent.com/<USER>/<REPO>/main/ssh-tun-dnat.sh")
ROLE=iran  bash <(curl -fsSL "https://raw.githubusercontent.com/<USER>/<REPO>/main/ssh-tun-dnat.sh")


این اسکریپت دقیقاً چه کارهایی می‌کند؟

روی khrej:

PermitTunnel yes و AllowTcpForwarding yes را در sshd_config ست می‌کند (لازمه‌ی ssh -w).

روی iran:

تون را با ssh -w TUN:TUN -N بالا می‌آورد.

IP/MTU تون را ست می‌کند

ip_forward=1 را فعال می‌کند

DNAT روی PREROUTING و MASQUERADE روی POSTROUTING می‌گذارد.

اگر خواستی MSS clamp هم فعال می‌کند تا مشکل MTU کمتر شود.

همه چیز را با systemd پایدار می‌کند و بعد از هر ری‌استارت سرویس، دوباره ستاپ را اعمال می‌کند.
