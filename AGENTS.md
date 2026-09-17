# Quy tắc Bảo mật & Biến Môi Trường (.env)

## 1. Nguyên Tắc Bắt Buộc Tuyệt Đối
- **KHÔNG BAO GIỜ** được gán cứng (hardcode) bất kỳ địa chỉ IP, tên máy chủ (server hostname), tên miền nội bộ (domain), tên tài khoản người dùng (username) hay mật khẩu (password) trong mã nguồn code.
- **Tất cả các thông tin môi trường, IP máy chủ, tài khoản, cấu hình nhạy cảm BẮT BUỘC phải đưa vào file `.env`**.
- Khi chạy công cụ, nếu không có file `.env`, hệ thống chỉ được phép lấy dữ liệu thông qua **input trực tiếp từ người dùng nhập vào trên terminal**, không bao giờ được tự ý lấy giá trị mặc định có chứa thông tin thật của hệ thống.

## 2. Quản Lý File `.env`
- File `.env` phải luôn luôn được liệt kê trong `.gitignore` để không bao giờ bị push lên Git repository.
- File `.env` trên máy trạm / máy chủ cần được phân quyền bảo vệ nghiêm ngặt:
  ```bash
  chmod 600 .env
  chown root:root .env
  ```
- Dự án phải luôn luôn cung cấp file mẫu `.env.example` chứa danh sách tên các biến cần thiết với giá trị placeholder mẫu (ví dụ: `example.com`, `192.168.1.10`), tuyệt đối không chứa dữ liệu thật.

## 3. Áp Dụng Cho Tất Cả Các Dự Án
- Mọi dự án lập trình sau này đều phải tuân thủ nghiêm ngặt chuẩn này.

---

## 4. Kinh Nghiệm Triển Khai Thực Tế & Xử Lý Lỗi Hệ Thống (AD & VNC)

### A. Quy Chuẩn Active Directory & Tên Máy (Hostname)
- **Chuẩn hóa Hostname:** Hostname của máy Linux phải đồng bộ thống nhất giữa `/etc/hostname` và `/etc/hosts`. Khi gia nhập AD, nếu tài khoản máy đã tồn tại từ trước trên Active Directory, cần cảnh báo và hướng dẫn reset/xóa object máy cũ trong AD Users & Computers để tránh lỗi `Insufficient permissions`.
- **Cấu hình Kerberos (`/etc/krb5.conf`):**
  - **Bắt buộc khóa Domain Controller cục bộ** trong khối `[realms]` (trỏ về IP của RODC/DC tại chi nhánh).
  - Phải thiết lập: `dns_lookup_realm = false`, `dns_lookup_kdc = false`, `rdns = false`. Tuyệt đối không bật `true` vì Kerberos sẽ truy vấn DNS SRV toàn cầu, bắt nhầm các DC ngoài WAN ở xa và gây lỗi kết nối `Offline`.
  - Luôn tự động sao lưu có gắn timestamp trước khi can thiệp: `cp -a /etc/krb5.conf /etc/krb5.conf.bak.$(date +%Y%m%d-%H%M%S)`.

### B. Khắc Phục Lỗi SSSD Offline Do Lệch Chữ Hoa/Thường Trong Keytab
- **Quy tắc phân biệt chữ hoa/thường (Case Sensitivity):** Kerberos phân biệt tuyệt đối chữ hoa/chữ thường. Khi join qua `adcli`, tài khoản máy trong `/etc/krb5.keytab` có thể là chữ thường (ví dụ: `hostname$@DOMAIN.COM`), trong khi SSSD mặc định tự động tìm chữ in hoa (`HOSTNAME$@DOMAIN.COM`). Khi không khớp, SSSD sẽ fallback sang SPN `host/...` (vốn không được phép xin vé TGT trong AD) dẫn đến lỗi `14 [Bad address]` và SSSD bị `Offline`.
- **Giải pháp bắt buộc:** Tool phải luôn tự động phân tích `/etc/krb5.keytab`, trích xuất chính xác tên machine principal thực tế và gán vào tham số:
  ```ini
  ldap_sasl_authid = <tên_chính_xác_trong_keytab>
  ```
  trong phần `[domain/<domain>]` của `/etc/sssd/sssd.conf`.

### C. Khắc Phục Lỗi Người Dùng AD Bị Chặn Đăng Nhập (GPO Access Control)
- SSSD mặc định áp dụng cơ chế Windows GPO Logon Rights khiến người dùng AD bị từ chối ở bước `pam_acct_mgmt`.
- **Giải pháp bắt buộc:** Luôn thiết lập `ad_gpo_access_control = permissive` trong `sssd.conf` để bỏ qua việc kiểm tra GPO Windows trên máy Linux.

### D. Quy Chuẩn VNC Tự Động Cho Mọi User Khi Logon (X11VNC Daemon)
- **Không bao giờ gán cứng DISPLAY `:0`:** Trên Zorin OS / Ubuntu hiện đại chạy GDM, màn hình đăng nhập (Greeter) thường chiếm `:0`, trong khi phiên desktop thực tế của người dùng đăng nhập lại chạy trên `:1` (hoặc ngược lại). Lệnh `loginctl` thường trả về `Display=` rỗng.
- **Giải pháp lấy DISPLAY & XAUTHORITY:** Script daemon (`zorin-x11vnc-daemon.sh`) bắt buộc phải đọc trực tiếp biến môi trường từ `/proc/<pid>/environ` của các tiến trình đồ họa thuộc UID của người dùng đang đăng nhập để lấy chính xác giá trị `DISPLAY` và đường dẫn file `Xauthority`.
- **Chống lỗi chia sẻ bộ nhớ `MIT-SHM BadAccess`:** Luôn bổ sung cờ `-noshm` khi khởi chạy `x11vnc` để tránh lỗi quyền bộ nhớ khi chạy chéo giữa root và user thường.
- **Phân quyền mật khẩu VNC:** File `/etc/x11vnc/vncpwd` và `/etc/x11vnc/passwd` phải có quyền `644`, thư mục `/etc/x11vnc` quyền `755` để mọi tài khoản người dùng khi logon vào đều đọc được mật khẩu kết nối.
- **Quản lý dịch vụ tập trung:** Sử dụng duy nhất service `zorin-x11vnc.service` để quản trị `/usr/local/bin/zorin-x11vnc-daemon.sh`. Tuyệt đối không để tồn tại service tĩnh `x11vnc.service` gán cứng một user gây xung đột cổng 5900.

