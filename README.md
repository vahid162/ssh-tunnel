# SSH TUN + DNAT (nasb kheili sade)

In project baraye tunnel **Iran -> Kharej** ast.

Hadaf: faghat ba **copy/paste command** ru har server, hame chiz automatic anjam shavad.

---

## Ejraye sari (faghat copy/paste)

> Tartib mohem: **aval server kharej, baad server iran**

### 1) Ru server Kharej in ra ejra kon

```bash
ROLE=khrej bash <(curl -fsSL https://raw.githubusercontent.com/vahid162/ssh-tunnel/main/ssh-tun-dnat.sh)
```

### 2) Ru server Iran in ra ejra kon

```bash
ROLE=iran bash <(curl -fsSL https://raw.githubusercontent.com/vahid162/ssh-tunnel/main/ssh-tun-dnat.sh)
```

Dar marhale Iran, script khodesh soal ha ra miporsad (IP kharej, SSH port, TUN ID, port ha va ...).

---

## Meghdarhaye pishnahadi baraye mobtadi (ru Iran)

- `TUN ID`: `5`
- `IP tunnel Iran`: `192.168.83.1`
- `IP tunnel Kharej`: `192.168.83.2`
- `Mask`: `30`
- `MTU`: `1240`
- `TCP ports`: mesl `443,2096`
- `MSS clamp`: `y`

Age motmaen nisti, pishfarz ha ra taghir nade.

---

## Agar link raw dar dastres nabood (kheili nadar)

```bash
# ru system khodet
scp ssh-tun-dnat.sh root@<SERVER_IP>:/root/

# ru haman server
ssh root@<SERVER_IP> 'ROLE=khrej bash /root/ssh-tun-dnat.sh'
ssh root@<SERVER_IP> 'ROLE=iran  bash /root/ssh-tun-dnat.sh'
```

---

## Check nahayi baad az nasb

### Ru Iran

```bash
ip a show tun5
systemctl status ssh-tun5-dnat.service --no-pager
iptables -t nat -vnL PREROUTING
```

### Ru Kharej

```bash
ip a show tun5
ss -lntup
```

> Agar `tun5` nist, adad 5 ra ba `TUN ID` khodet avaz kon.

---

## Agar moshkel dashti in khoroji ha ra befrest

### Iran

```bash
ip a
systemctl status ssh-tun5-dnat.service --no-pager
journalctl -u ssh-tun5-dnat.service -n 200 --no-pager
iptables -t nat -vnL
iptables -vnL FORWARD
```

### Kharej

```bash
ip a
ss -lntup
cat /etc/ssh/sshd_config | sed -n '1,220p'
```

Man ba hamin khoroji ha daghigh va ghadam-be-ghadam moshkel ra peyda mikonam.
