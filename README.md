# Zorin OS Active Directory Join & X11VNC Management Tool

Bộ công cụ quản trị hệ thống toàn diện dành cho **Zorin OS (Ubuntu/Debian based)**, giúp tự động hóa việc gia nhập **Microsoft Active Directory (AD)**, cấu hình SSSD/PAM/GDM và quản lý dịch vụ **x11vnc** tự động gắn vào đúng phiên làm việc đồ họa (Xorg Desktop) của người dùng Active Directory khi đăng nhập.

---

## 🌟 Tính Năng Nổi Bật

1. **Bảo mật tuyệt đối (Nhập tay thông tin xác thực)**:
   - Tên tài khoản AD Administrator và mật khẩu được **nhập tay từ bàn phím** với chế độ ẩn ký tự (`read -s`).
   - Mật khẩu truyền trực tiếp qua pipe/stdin khi join domain, **tuyệt đối không hard-code** vào mã nguồn, không lưu plaintext và không ghi vào file nhật ký (logs).
2. **Dynamic User Session Detection cho x11vnc**:
   - Tự động phát hiện phiên đồ họa người dùng AD đang hoạt động trên màn hình `seat0` thông qua `loginctl`.
   - Lấy chính xác `UID`, `DISPLAY=:0`, và đường dẫn xác thực `XAUTHORITY` (`/run/user/<UID>/gdm/Xauthority`).
   - Khởi chạy `x11vnc` **trực tiếp dưới danh tính của chính AD User đó** (`sudo -u <user> ...`).
   - Không chạy x11vnc dưới quyền admin cho phiên làm việc của domain user.
   - Khi user logout, service tự giải phóng và sẵn sàng cho user tiếp theo.
3. **Ép sử dụng Xorg thay vì Wayland**:
   - Tự động cấu hình `/etc/gdm3/custom.conf` với `WaylandEnable=false`.
4. **Tự động tạo và sửa quyền Home Directory**:
   - Cấu hình PAM `pam_mkhomedir.so` với umask an toàn `0077`.
   - Tích hợp công cụ **Repair User Home Directory** giúp sửa triệt để lỗi thư mục gốc bị gán quyền `root:root` gây crash Xorg.
5. **Quản lý AD GPO Access Control**:
   - Hỗ trợ chuyển đổi linh hoạt giữa chế độ **Enforcing** (Chuẩn bảo mật) và **Permissive** (Khắc phục lỗi GPO mapping khi cần thiết).
6. **Bảng kiểm tra sức khỏe hệ thống (Health Check Dashboard)**:
   - Kiểm tra trực quan 14 tiêu chí: DNS, Kerberos, LDAP, Realm, SSSD, PAM, Home Dir, GDM, Xorg, x11vnc và Port 5900.
7. **Sao lưu & Khôi phục (Backup & Rollback)**:
   - Tự động tạo bản sao lưu có gắn mốc thời gian trước khi thay đổi bất kỳ file cấu hình nào trong `/etc`.
8. **Quản lý Thư mục chia sẻ mạng (Windows SMB/CIFS File Share)**:
   - Tra cứu share trên Windows File Server (`smbclient -L`).
   - Mount thư mục mạng với xác thực Domain AD (lưu credentials 0600) hoặc Kerberos SSO.
   - Tùy chọn tự động mount khi khởi động máy qua `/etc/fstab`.
9. **Quản lý Máy in chia sẻ qua mạng (Network Printer CUPS/SMB/IP)**:
   - Thêm máy in mạng trực tiếp theo IP qua RAW Socket Port 9100 hoặc IPP 631 (Canon, HP, Ricoh, Brother,...).
   - Thêm máy in từ Windows Print Server trong Domain qua SMB (`smb://server/printer`).
   - In trang thử nghiệm (Print Test Page) và đặt máy in mặc định.

---

## 📋 Yêu Cầu Hệ Thống

- **Hệ điều hành**: Zorin OS 16 / 17 (hoặc Ubuntu 20.04 / 22.04 / 24.04).
- **Quyền hạn**: Quyền `root` hoặc `sudo`.
- **Mạng**: Kết nối tới Active Directory Domain Controllers (ví dụ: `10.0.60.19`, `10.0.60.20`).
- **Cổng dịch vụ cần mở trên AD**:
  - TCP 88 (Kerberos)
  - TCP 389 (LDAP)
  - TCP 53 / UDP 53 (DNS)

---

## 🚀 Hướng Dẫn Sử Dụng Nhanh (Quick Start)

Mỗi lần cài đặt một máy Zorin OS mới, bạn chỉ cần mở Terminal và thực hiện 3 bước sau:

### Bước 1: Clone kho lưu trữ từ GitHub

```bash
git clone https://github.com/<your-username>/ZorinOS-tool.git
cd ZorinOS-tool
```

### Bước 2: Cấp quyền thực thi và Cài đặt

```bash
# Cấp quyền thực thi cho các file script
sudo chmod +x *.sh lib/*.sh

# Cài đặt công cụ vào hệ thống (/usr/local/bin/zorin-ad-vnc)
sudo ./install.sh
```

### Bước 3: Khởi chạy công cụ Quản trị

Sau khi cài đặt xong, bạn có thể chạy công cụ từ bất kỳ đâu:

```bash
sudo zorin-ad-vnc
```

Hoặc chạy trực tiếp từ thư mục vừa clone:

```bash
sudo ./zorin-ad-vnc.sh
```

---

## 🖥 Giao Diện Menu Tương Tác (CLI / TUI)

Khi khởi chạy, công cụ hiển thị Menu trực quan:

```text
================================================================
       ZORIN OS AD JOIN & X11VNC MANAGEMENT TOOL                
           Hỗ trợ AD Domain: bestpacific.com | OS: Zorin OS      
================================================================
 1.  System Information              (Thông tin hệ thống)
 2.  DNS / AD Connectivity Check     (Kiểm tra DNS/AD Controllers)
 3.  Join Active Directory           (Gia nhập AD - User/Pass nhập tay)
 4.  Configure SSSD                  (Cấu hình SSSD / AD GPO)
 5.  Configure PAM / Home Directory  (Bật pam_mkhomedir tự tạo home)
 6.  Configure GDM / Force Xorg      (Ép dùng Xorg thay vì Wayland)
 7.  Test AD User                    (Kiểm tra tài khoản AD / kinit)
 8.  Set VNC Password                (Đặt mật khẩu VNC an toàn)
 9.  Configure Domain User X11VNC    (Cài đặt & Bật Dynamic VNC Service)
 10. VNC Service Status              (Trạng thái x11vnc & Port 5900)
 11. AD / SSSD Status                (Trạng thái realm & sssd)
 12. Repair User Home Directory      (Sửa lỗi quyền root của Home Dir)
 13. Health Check Dashboard          (Bảng kiểm tra tổng quan 14 tiêu chí)
 14. View Logs                       (Xem nhật ký hệ thống)
 15. Backup / Rollback Config        (Sao lưu & Khôi phục cấu hình)
 16. Automated Quick Setup           (Chạy tuần tự toàn bộ cho máy mới)
 17. Leave Active Directory          (Rời khỏi miền AD)
 18. Network File Share (SMB/CIFS)   (Quản lý thư mục chia sẻ Windows/AD)
 19. Network Printer Manager         (Quản lý máy in CUPS/SMB/IP)
 0.  Exit                            (Thoát công cụ)
----------------------------------------------------------------
```

---

## ⚡ Quy Trình Thiết Lập Cho Máy Mới

Đối với máy mới cài đặt, bạn chỉ cần chọn **Mục 16 (Automated Quick Setup)**. Tool sẽ thực hiện tuần tự:

1. **Kiểm tra mạng & DNS**: Phân giải tên miền AD và kiểm tra cổng LDAP/Kerberos.
2. **Cài đặt các gói phụ thuộc**: `realmd`, `sssd`, `adcli`, `krb5-user`, `oddjob-mkhomedir`, `x11vnc`,...
3. **Nhập thông tin AD**: Yêu cầu nhập Domain, DC IP, tài khoản Administrator và mật khẩu (ẩn ký tự).
4. **Gia nhập Domain**: Thực thi `realm join` bảo mật.
5. **Cấu hình SSSD**: Tối ưu hóa tên người dùng ngắn (`use_fully_qualified_names = False`), thư mục home `/home/%u@%d`, phân quyền `chmod 600`.
6. **Cấu hình PAM**: Đảm bảo `pam_mkhomedir.so` hoạt động.
7. **Ép dùng Xorg**: Tắt Wayland trong `/etc/gdm3/custom.conf`.
8. **Đặt mật khẩu VNC**: Nhập mật khẩu VNC (tối đa 8 ký tự theo chuẩn RFB).
9. **Kích hoạt Daemon**: Bật `zorin-x11vnc.service`.
10. **Reboot**: Khởi động lại máy để áp dụng Xorg.

Sau khi Reboot, bất kỳ AD user nào (ví dụ: `vnit024`) đăng nhập vào Zorin GUI:
- Màn hình desktop Xorg sẽ khởi chạy.
- Dịch vụ nền tự động nhận diện và kích hoạt `x11vnc` gắn vào đúng desktop của user đó.
- IT Admin có thể kết nối VNC tới IP máy trạm qua cổng `5900` với mật khẩu đã đặt.

---

## 🛠 Các Lệnh CLI Hữu Ích

Ngoài menu tương tác, bạn có thể gọi trực tiếp các tính năng bằng tham số dòng lệnh:

| Lệnh | Mô tả |
| :--- | :--- |
| `sudo zorin-ad-vnc --check` | Chạy nhanh bảng kiểm tra Health Check |
| `sudo zorin-ad-vnc --status` | Xem trạng thái kết nối VNC và port 5900 |
| `sudo zorin-ad-vnc --auto-setup` | Chạy chế độ cài đặt tự động cho máy mới |
| `sudo zorin-ad-vnc --repair vnit024` | Sửa quyền sở hữu thư mục Home cho user `vnit024` |
| `sudo zorin-ad-vnc --toggle-gpo` | Chuyển đổi qua lại giữa GPO Enforcing và Permissive |
| `sudo zorin-ad-vnc --share` | Mở menu quản lý Thư mục chia sẻ mạng (SMB/CIFS) |
| `sudo zorin-ad-vnc --printer` | Mở menu quản lý Máy in chia sẻ qua mạng |
| `sudo zorin-ad-vnc --help` | Hiển thị hướng dẫn sử dụng các tham số |

---

## 📊 Bảng Kiểm Tra Sức Khỏe (Health Check Example)

Khi chạy tính năng Health Check (Mục 13 hoặc `--check`), bạn sẽ nhận được báo cáo trực quan:

```text
               ZORIN AD / X11VNC HEALTH CHECK DASHBOARD               
======================================================================
DNS Resolution (bestpacific.com) [ ✓ OK ]
AD1 Reachable (10.0.60.19)       [ ✓ OK ]
AD2 Reachable (10.0.60.20)       [ ✓ OK ]
Kerberos KDC (Port 88)           [ ✓ OK ]
Realm Domain Joined              [ ✓ OK (bestpacific.com) ]
SSSD Service                     [ ✓ RUNNING ]
AD User Lookup (vnit024)         [ ✓ OK ]
PAM mkhomedir                    [ ✓ CONFIGURED ]
GDM Wayland Disabled             [ ✓ OK (Wayland=false) ]
Current Session Type             [ ✓ X11 ]
Xorg Server Process              [ ✓ RUNNING ]
zorin-x11vnc.service             [ ✓ ACTIVE ]
VNC Port 5900                    [ ✓ LISTENING ]
----------------------------------------------------------------------
THÔNG TIN PHIÊN ĐỒ HỌA HIỆN TẠI (ACTIVE GUI SESSION):
  Current Desktop User : vnit024
  Session ID           : 43
  User UID             : 1216265280
  Display              : :0
  Xauthority           : /run/user/1216265280/gdm/Xauthority
  x11vnc Running User  : vnit024
======================================================================
```

---

## 🔧 Xử Lý Sự Cố Thường Gặp (Troubleshooting)

### 1. Lỗi Xorg không khởi động được do quyền Home Directory
- **Hiện tượng**: User AD login bị văng ra lại màn hình GDM, log báo `Cannot open log file /home/user/.local/share/xorg/Xorg.0.log: Permission denied`.
- **Nguyên nhân**: Thư mục Home được tạo với quyền `root:root`.
- **Giải pháp**: Chạy `sudo zorin-ad-vnc --repair <username>`. Tool sẽ tự lấy UID và Primary GID thực tế của user từ AD và cập nhật `chown -R` cùng `chmod 700`.

### 2. Lỗi SSSD từ chối đăng nhập do GPO
- **Hiện tượng**: `GPO-based access control failed` hoặc PAM service không khớp GPO.
- **Giải pháp**: Chọn **Mục 4** trong menu hoặc chạy `sudo zorin-ad-vnc --toggle-gpo`, chọn chế độ **Permissive** để troubleshooting.

### 3. Phiên đăng nhập hiển thị Wayland thay vì X11
- **Hiện tượng**: `XDG_SESSION_TYPE=wayland`, x11vnc không thể attach màn hình.
- **Giải pháp**: Chọn **Mục 6** để ép cấu hình `WaylandEnable=false`, sau đó khởi động lại máy (`sudo reboot`).

---

## 📂 Cấu Trúc Dự Án

```text
ZorinOS-tool/
├── zorin-ad-vnc.sh               # Tool chính - Interactive CLI Menu & CLI commands
├── install.sh                    # Script cài đặt tiện ích toàn cục (/usr/local/bin)
├── systemd/
│   └── zorin-x11vnc.service      # Systemd service quản lý vòng đời x11vnc theo session
├── lib/
│   ├── common.sh                 # Hàm dùng chung: logging, colors, input mật khẩu an toàn
│   ├── check_dns.sh              # Kiểm tra DNS, Kerberos, AD Domain Controller reachability
│   ├── ad_join.sh                # Cài đặt gói phụ thuộc, realm join với user/pass nhập tay
│   ├── sssd_config.sh            # Cấu hình SSSD, GPO (Enforcing/Permissive), backup sssd.conf
│   ├── pam_homedir.sh            # Cấu hình pam_mkhomedir và công cụ sửa quyền Home Dir
│   ├── gdm_xorg.sh               # Ép GDM3 chạy Xorg thay vì Wayland (WaylandEnable=false)
│   ├── vnc_manager.sh            # Cài đặt x11vnc, đặt mật khẩu VNC an toàn, quản trị service
│   ├── x11vnc_session_daemon.sh  # Engine nhận diện dynamic GUI user trên seat0 & attach x11vnc
│   ├── health_check.sh           # Bảng kiểm tra toàn diện 14 tiêu chí (Dashboard OK/FAILED)
│   ├── backup_rollback.sh        # Tự động backup cấu hình và tính năng khôi phục (Rollback)
│   ├── smb_share.sh              # Quản lý thư mục chia sẻ mạng Windows/AD (SMB/CIFS)
│   └── printer_manager.sh        # Quản lý máy in mạng (CUPS / RAW 9100 / IPP / SMB Print Server)
├── .gitignore                    # Bỏ qua log, backup tạm, mật khẩu vnc
├── LICENSE                       # Giấy phép MIT
└── README.md                     # Tài liệu hướng dẫn sử dụng chi tiết
```

---

## 📜 Giấy Phép (License)

Dự án được phân phối dưới giấy phép mã nguồn mở [MIT License](LICENSE).
