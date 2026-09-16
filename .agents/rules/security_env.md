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
