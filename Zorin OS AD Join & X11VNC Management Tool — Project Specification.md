# Zorin OS AD Join & X11VNC Management Tool

## 1. Mục tiêu

Xây dựng một tool quản trị chạy trực tiếp trên Zorin OS nhằm tự động hóa:

1. Join Zorin OS vào Microsoft Active Directory.
2. Kiểm tra và cấu hình DNS/Kerberos/SSSD.
3. Cho phép user Active Directory đăng nhập vào Zorin Desktop.
4. Tự động tạo và cấu hình Home Directory cho AD user.
5. Cấu hình Zorin/GDM sử dụng Xorg thay vì Wayland.
6. Cài đặt và cấu hình x11vnc.
7. Cho phép admin sử dụng VNC để truy cập desktop local.
8. Khi một AD user đăng nhập GUI, x11vnc phải tự động attach vào đúng Xorg desktop của user đó.
9. Không được attach nhầm vào desktop của admin.
10. Có thể kiểm tra trạng thái AD join, AD authentication, Xorg và x11vnc từ một giao diện/tool duy nhất.

---

# 2. Môi trường mục tiêu

OS:

- Zorin OS
- Ubuntu/Debian based
- GNOME/Zorin Desktop
- GDM3
- Xorg

Active Directory:

```text
Domain: bestpacific.com

AD1:
10.0.60.19

AD2:
10.0.60.20
```

Ví dụ user:

```text
vnit024
```

Domain user có thể đăng nhập:

```text
vnit024
```

hoặc:

```text
vnit024@bestpacific.com
```

---

# 3. Kiến trúc mong muốn

```text
                    Active Directory
                  bestpacific.com
                   /            \
          10.0.60.19            10.0.60.20
              AD1                    AD2
                \                    /
                 \                  /
                  Zorin OS Client
                       |
                       |
                +------+------+
                |             |
              GDM3          SSSD
                |             |
              Xorg         Kerberos
                |             |
          GNOME/Zorin      AD User
                |
             x11vnc
                |
             TCP/5900
                |
          VNC Client
```

---

# 4. AD Join

Tool phải hỗ trợ:

```text
Discover Domain
    ↓
Check DNS
    ↓
Check Kerberos
    ↓
Join Domain
    ↓
Configure SSSD
    ↓
Configure PAM
    ↓
Configure GDM
```

Các package cần kiểm tra/cài đặt:

```bash
realmd
sssd
sssd-ad
sssd-tools
libnss-sss
libpam-sss
adcli
samba-common-bin
krb5-user
packagekit
oddjob
oddjob-mkhomedir
libpam-mkhomedir
```

Có thể cài:

```bash
sudo apt install -y \
realmd \
sssd \
sssd-ad \
sssd-tools \
libnss-sss \
libpam-sss \
adcli \
samba-common-bin \
krb5-user \
packagekit \
oddjob \
oddjob-mkhomedir \
libpam-mkhomedir
```

Tool phải kiểm tra trước khi join:

```bash
hostname -f
resolvectl status
getent hosts bestpacific.com
getent hosts bpvn-ad01.bestpacific.com
getent hosts bpvn-ad02.bestpacific.com
```

Sau đó:

```bash
realm discover bestpacific.com
```

và:

```bash
realm join bestpacific.com -U Administrator
```

Không hard-code password Administrator vào source code.

---

# 5. SSSD

SSSD configuration mẫu:

```ini
[sssd]
services = nss, pam, ssh
config_file_version = 2
domains = bestpacific.com

[domain/bestpacific.com]
id_provider = ad
access_provider = ad

fallback_homedir = /home/%u@%d
use_fully_qualified_names = False
```

Tool phải backup:

```text
/etc/sssd/sssd.conf
```

trước khi sửa.

Sau khi sửa:

```bash
chmod 600 /etc/sssd/sssd.conf
systemctl restart sssd
```

Kiểm tra:

```bash
realm list
sssctl domain-status bestpacific.com
id vnit024
getent passwd vnit024
```

---

# 6. Home Directory

Đây là lỗi thực tế đã gặp và phải xử lý.

AD user login thành công nhưng Home Directory được tạo với:

```text
root:root
```

khiến Xorg không thể tạo:

```text
.local/share/xorg
.local/share/keyrings
.local/state/wireplumber
```

Kết quả:

```text
Xorg Fatal server error
Cannot open log file ...
Permission denied
```

Tool phải kiểm tra Home Directory của user.

Ví dụ:

```bash
getent passwd vnit024
```

kết quả:

```text
/home/vnit024@bestpacific.com
```

Tool phải đảm bảo:

```text
owner = vnit024
group = primary group của vnit024
permission = 700
```

Ví dụ:

```bash
chown -R vnit024:<primary-group> /home/vnit024@bestpacific.com
chmod 700 /home/vnit024@bestpacific.com
```

Không được hard-code UID/GID.

Phải lấy bằng:

```bash
id vnit024
```

---

# 7. PAM / Home Directory tự động

Tool phải kiểm tra:

```bash
/etc/pam.d/common-session
```

có:

```text
session optional pam_mkhomedir.so
```

Nếu chưa có thì cấu hình.

Mục tiêu:

```text
AD User Login
       ↓
PAM
       ↓
pam_sss
       ↓
pam_mkhomedir
       ↓
/home/<user>@<domain>
```

---

# 8. AD GPO Access Control

Trong quá trình triển khai đã gặp:

```text
PAM service 'ssh' is not mapped to any Group Policy rule
GPO-based access control failed
```

SSSD mặc định deny login do AD GPO.

Để troubleshooting có thể sử dụng:

```ini
ad_gpo_access_control = permissive
```

Nhưng đây **không nên là default production configuration**.

Tool nên có:

```text
AD GPO Access Control:
    [ Enforcing ]
    [ Permissive ]
```

Default:

```text
Enforcing
```

Không thay thế bằng:

```ini
access_provider = permit
```

vì sẽ làm mất kiểm soát truy cập AD.

---

# 9. GDM / Xorg

x11vnc chỉ hoạt động với X11/Xorg.

Tool phải đảm bảo Zorin sử dụng Xorg:

```ini
/etc/gdm3/custom.conf

[daemon]
WaylandEnable=false
```

Sau đó restart/reboot GDM.

Kiểm tra:

```bash
echo $XDG_SESSION_TYPE
```

phải:

```text
x11
```

Có thể kiểm tra:

```bash
loginctl show-session <SESSION_ID> -p Type
```

Expected:

```text
Type=x11
```

---

# 10. X11VNC

Tool phải tự động cài:

```bash
apt install -y x11vnc
```

Kiểm tra:

```bash
x11vnc -version
```

---

# 11. Admin X11VNC

Tool phải có chức năng:

```text
Configure Admin VNC
```

Mục tiêu:

```text
Local Admin Desktop
        ↓
Xorg :0
        ↓
x11vnc
        ↓
TCP 5900
```

Có VNC password.

Không chạy production với:

```text
x11vnc -forever -shared
```

mà không có authentication.

Tạo password:

```bash
x11vnc -storepasswd ~/.vnc/passwd
```

và dùng:

```text
-rfbauth ~/.vnc/passwd
```

---

# 12. Domain User X11VNC

Đây là phần quan trọng nhất.

Khi AD user login:

```text
GDM
 ↓
vnit024
 ↓
Xorg
 ↓
GNOME/Zorin
```

x11vnc phải attach vào **desktop của chính user đó**.

Không được dùng session của admin.

Ví dụ thực tế:

```text
Session:
43

UID:
1216265280

User:
vnit024

Xorg PID:
134658

Xorg auth:
/run/user/1216265280/gdm/Xauthority

DISPLAY:
:0
```

Command đã test thành công:

```bash
sudo -u vnit024 env \
DISPLAY=:0 \
XAUTHORITY=/run/user/1216265280/gdm/Xauthority \
x11vnc \
-display :0 \
-auth /run/user/1216265280/gdm/Xauthority \
-forever \
-shared \
-rfbport 5900 \
-noxdamage
```

Tool phải tự động phát hiện:

```text
Current graphical user
UID
Session ID
DISPLAY
XAUTHORITY
Xorg PID
```

Không hard-code:

```text
1216265280
```

hoặc:

```text
vnit024
```

---

# 13. Dynamic User Detection

Tool phải lấy graphical session từ:

```bash
loginctl list-sessions
```

Ví dụ:

```text
SESSION UID USER      SEAT  TTY STATE
43      ... vnit024   seat0 tty2 active
```

Sau đó:

```bash
loginctl show-session 43
```

Xác định:

```text
User
UID
Seat
Type
State
```

Chỉ chọn session:

```text
Seat = seat0
State = active
Type = x11
```

Sau đó tìm Xorg:

```bash
ps aux | grep '[X]org'
```

Xorg command line chứa:

```text
-auth /run/user/<UID>/gdm/Xauthority
```

Tool phải parse Xauthority path.

---

# 14. X11VNC Lifecycle

Mong muốn:

```text
User logout
    ↓
Xorg terminate
    ↓
x11vnc terminate

User login
    ↓
GDM
    ↓
Xorg starts
    ↓
Xauthority created
    ↓
GNOME starts
    ↓
x11vnc starts
```

Không chạy x11vnc cố định dưới admin để phục vụ mọi user.

Nên thiết kế một service/agent có khả năng:

```text
Detect active Xorg session
        ↓
Detect user
        ↓
Detect DISPLAY
        ↓
Detect XAUTHORITY
        ↓
Start x11vnc as that user
```

---

# 15. X11VNC Security

Tool phải hỗ trợ:

```text
VNC Password
```

Ví dụ:

```bash
~/.vnc/passwd
```

Permission:

```text
600
```

Không lưu password plaintext trong config.

Có thể hỗ trợ:

```text
VNC Port: 5900
```

và configurable.

Nên có tùy chọn:

```text
Enable/Disable VNC
VNC Port
VNC Password
Listen Address
```

Có thể giới hạn firewall chỉ cho subnet IT/management.

---

# 16. Tool UI

Có thể làm CLI trước, GUI sau.

CLI đề xuất:

```text
zorin-ad-vnc
```

Menu:

```text
================================================
 Zorin AD + X11VNC Management Tool
================================================

1. System Information
2. DNS / AD Connectivity Check
3. Join Active Directory
4. Configure SSSD
5. Configure PAM / Home Directory
6. Configure GDM / Xorg
7. Test AD User
8. Configure Admin X11VNC
9. Configure Domain User X11VNC
10. VNC Status
11. AD / SSSD Status
12. Repair User Home Directory
13. Logs
14. Uninstall / Rollback
0. Exit
```

---

# 17. Automatic Health Check

Tool cần có:

```text
[✓] DNS
[✓] AD1 reachable
[✓] AD2 reachable
[✓] Kerberos
[✓] Realm joined
[✓] SSSD running
[✓] AD user lookup
[✓] PAM
[✓] Home directory
[✓] GDM
[✓] Xorg
[✓] X11VNC
[✓] VNC port
```

Ví dụ:

```text
Zorin AD/VNC Health Check

DNS                         [ OK ]
AD Domain                   [ OK ]
Kerberos                    [ OK ]
Realm                       [ OK ]
SSSD                        [ OK ]
AD User Lookup              [ OK ]
PAM                         [ OK ]
Home Directory             [ OK ]
GDM                         [ OK ]
Session Type                [ X11 ]
Xorg                        [ OK ]
Xauthority                 [ OK ]
x11vnc                      [ OK ]
VNC Port 5900              [ LISTENING ]

Current Desktop User:
vnit024

Session:
43

Display:
:0

Xauthority:
/run/user/1216265280/gdm/Xauthority
```

---

# 18. Logging

Tool phải có log:

```text
/var/log/zorin-ad-vnc.log
```

Log các bước:

```text
AD discovery
AD join
SSSD configuration
PAM configuration
GDM configuration
User detection
Xorg detection
Xauthority detection
x11vnc start/stop
VNC connection/service errors
```

Không ghi password AD/VNC vào log.

---

# 19. Backup / Rollback

Trước khi sửa:

```text
/etc/sssd/sssd.conf
/etc/gdm3/custom.conf
/etc/pam.d/common-session
systemd service files
```

Tool phải backup.

Ví dụ:

```text
/var/backups/zorin-ad-vnc/<timestamp>/
```

Có chức năng:

```text
Rollback Configuration
```

---

# 20. Important Design Requirements

### Không hard-code

Không hard-code:

```text
UID
GID
AD username
Xauthority UID
session ID
Xorg PID
```

Phải dynamic detect.

### Không assume DISPLAY

Không dùng:

```text
DISPLAY=localhost:10.0
```

vì đó có thể là SSH X11 forwarding.

Phải detect graphical session:

```text
DISPLAY=:0
```

### Không chạy x11vnc dưới admin cho domain user

Sai:

```text
admin → x11vnc → vnit024 desktop
```

Đúng:

```text
vnit024 → Xorg → x11vnc → vnit024 desktop
```

### Chỉ hỗ trợ Xorg

Tool phải kiểm tra:

```text
XDG_SESSION_TYPE=x11
```

Nếu:

```text
wayland
```

thì cảnh báo:

```text
x11vnc requires X11/Xorg.
Current session is Wayland.
```

---

# 21. Target User Experience

Sau khi cài tool trên một máy Zorin mới:

```text
Install Tool
      ↓
Enter AD Domain
      ↓
Enter AD Administrator credentials
      ↓
Tool checks DNS
      ↓
Join AD
      ↓
Configure SSSD
      ↓
Configure PAM
      ↓
Configure GDM
      ↓
Force Xorg
      ↓
Install x11vnc
      ↓
Configure VNC password
      ↓
Reboot
```

Sau reboot:

```text
GDM Login
     ↓
AD user enters:
vnit024
password
     ↓
SSSD authenticates against AD
     ↓
Home directory created
     ↓
Zorin Desktop starts
     ↓
Tool detects:
    User = vnit024
    Session = 43
    Display = :0
    Xauthority = /run/user/<UID>/gdm/Xauthority
     ↓
x11vnc starts
     ↓
VNC Client → Zorin Desktop
```

Mục tiêu cuối cùng:

> **Một máy Zorin OS có thể join AD và cho phép bất kỳ AD user được phép nào đăng nhập vào Zorin GUI. Khi user đăng nhập, x11vnc tự động chạy dưới chính user đó và remote đúng desktop Xorg của user, thay vì desktop của admin.**