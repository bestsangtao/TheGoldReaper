# Kích hoạt The Gold Reaper bằng Google Sheet

EA xác thực chính xác số tài khoản MT5, trạng thái, ngày hết hạn, server và sản phẩm. Google Sheet có thể để riêng tư; chỉ Google Apps Script web app được công khai để trả về kết quả tối thiểu.

## 1. Tạo bảng `Licenses`

Tạo tab có tên chính xác `Licenses`. Sáu cột đầu là phần quản trị:

| Account | Active | ExpiryUTC | CustomerName | AllowedServer | Product |
| --- | --- | --- | --- | --- | --- |
| 12345678 | TRUE | 2026-12-31 23:59:59 | Customer A | ICMarketsSC-MT5-6 | The Gold Reaper v4.6 |

Các cột tiếp theo do EA tự cập nhật: `AccountName`, `Broker`,
`DetectedServer`, `Currency`, `Balance`, `Equity`, `Leverage`, `TradeMode`,
`Symbol`, `Terminal`, `TerminalBuild`, `FirstSeenUTC`, `LastSeenUTC` và
`LastResult`.

- `Account` và `Active` là bắt buộc.
- `ExpiryUTC`, `CustomerName`, `AllowedServer`, `Product` là tùy chọn.
- Để `ExpiryUTC` trống hoặc nhập `0` nếu không hết hạn.
- Để `AllowedServer`/`Product` trống hoặc nhập `*` để cho phép mọi giá trị.
- Các trạng thái hợp lệ: `ACTIVE`, `ENABLED`, `TRUE`, `YES`, `1`, `OK`.
- Tài khoản MT5 chưa có trong bảng sẽ tự được thêm với `Active = FALSE`.

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

## Hành vi

- Khi gắn EA, thông tin tài khoản được gửi lên Sheet ngay lập tức.
- Khi `Active = FALSE`, EA vẫn nằm trên biểu đồ nhưng không khởi tạo chiến lược,
  không dựng panel và tự kiểm tra lại mỗi 10 giây.
- Khi đổi `Active = TRUE`, EA tự khởi tạo và hoạt động bình thường mà không cần
  gắn lại vào biểu đồ.
- Sau khi kích hoạt, EA kiểm tra lại mỗi 60 giây.
- Lỗi mạng tạm thời dùng kết quả hợp lệ gần nhất tối đa 3 giờ trong phiên chạy hiện tại.
- Khi tài khoản bị tắt hoặc hết hạn, EA xóa pending, đóng vị thế mang Magic
  Number của Gold Reaper rồi tự gỡ khỏi biểu đồ. Lệnh tay và lệnh của EA khác
  không bị tác động.
- Strategy Tester tự bỏ qua xác thực vì MetaTrader không hỗ trợ `WebRequest` trong Tester.

EA cũng đọc được Google Sheet CSV đã publish nếu URL CSV được đặt trực tiếp vào `GR_LICENSE_WEB_APP_URL`; khi đó phải cho phép thêm `https://docs.google.com` trong WebRequest. Cách CSV làm lộ toàn bộ danh sách, vì vậy Apps Script là lựa chọn nên dùng.
