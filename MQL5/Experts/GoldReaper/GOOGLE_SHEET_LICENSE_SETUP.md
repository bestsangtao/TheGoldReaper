# Kích hoạt The Gold Reaper bằng Google Sheet

EA xác thực chính xác số tài khoản MT5, trạng thái, ngày hết hạn, server và sản phẩm. Google Sheet có thể để riêng tư; chỉ Google Apps Script web app được công khai để trả về kết quả tối thiểu.

## 1. Tạo bảng `Licenses`

Tạo tab có tên chính xác `Licenses`, với hàng đầu tiên:

| Account | Active | ExpiryUTC | Name | Server | Product |
| --- | --- | --- | --- | --- | --- |
| 12345678 | TRUE | 2026-12-31 23:59:59 | Customer A | ICMarketsSC-MT5-6 | The Gold Reaper v4.6 |

- `Account` và `Active` là bắt buộc.
- `ExpiryUTC`, `Name`, `Server`, `Product` là tùy chọn.
- Để `ExpiryUTC` trống hoặc nhập `0` nếu không hết hạn.
- Để `Server`/`Product` trống hoặc nhập `*` để cho phép mọi giá trị.
- Các trạng thái hợp lệ: `ACTIVE`, `ENABLED`, `TRUE`, `YES`, `1`, `OK`.

## 2. Triển khai Apps Script

1. Trong Google Sheet, mở **Extensions → Apps Script**.
2. Dán nội dung file `GoogleSheetLicense.gs`.
3. Chọn **Deploy → New deployment → Web app**.
4. Chọn **Execute as: Me** và **Who has access: Anyone**.
5. Sao chép URL kết thúc bằng `/exec`.

Tùy chọn: vào **Project Settings → Script properties**, tạo `LICENSE_API_KEY`. Nếu dùng khóa này, giá trị trong `GR_LICENSE_ACCESS_KEY` của EA phải giống hệt.

## 3. Cấu hình EA

Trong `The Gold Reaper v4.6.mq5`, điền các hằng số rồi biên dịch lại:

```mql5
#define GR_LICENSE_WEB_APP_URL "https://script.google.com/macros/s/DEPLOYMENT_ID/exec"
#define GR_LICENSE_ACCESS_KEY  ""
```

Trong MT5, mở **Tools → Options → Expert Advisors**, bật WebRequest và thêm:

- `https://script.google.com`
- `https://script.googleusercontent.com`

## Hành vi

- Live/demo phải được Sheet chấp thuận ngay trong `OnInit`.
- EA kiểm tra lại mỗi 15 phút.
- Lỗi mạng tạm thời dùng kết quả hợp lệ gần nhất tối đa 3 giờ trong phiên chạy hiện tại.
- Khi tài khoản bị tắt hoặc hết hạn, EA chặn lệnh mới nhưng vẫn sửa, đóng và xóa lệnh cũ để không bỏ rơi giao dịch đang mở.
- Strategy Tester tự bỏ qua xác thực vì MetaTrader không hỗ trợ `WebRequest` trong Tester.

EA cũng đọc được Google Sheet CSV đã publish nếu URL CSV được đặt trực tiếp vào `GR_LICENSE_WEB_APP_URL`; khi đó phải cho phép thêm `https://docs.google.com` trong WebRequest. Cách CSV làm lộ toàn bộ danh sách, vì vậy Apps Script là lựa chọn nên dùng.
