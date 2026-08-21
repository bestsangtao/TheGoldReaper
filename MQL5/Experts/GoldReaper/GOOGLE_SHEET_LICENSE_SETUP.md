# Kích hoạt The Gold Reaper bằng Google Sheet

EA xác thực chính xác số tài khoản MT5, trạng thái, ngày hết hạn, server và sản phẩm. Google Sheet có thể để riêng tư; chỉ Google Apps Script web app được công khai để trả về kết quả tối thiểu.

## 1. Tạo bảng `Licenses`

Tạo tab có tên chính xác `Licenses`. Sáu cột đầu là phần quản trị:

| Name | Account | Active | ExpiryUTC | AllowedServer | Product |
| --- | --- | --- | --- | --- | --- |
| Customer A | 12345678 | TRUE | 2026-12-31 23:59:59 | ICMarketsSC-MT5-6 | The Gold Reaper v4.6 |

Các cột tiếp theo do EA tự cập nhật: `AccountName`, `Broker`,
`DetectedServer`, `Currency`, `Balance`, `Equity`, `Leverage`, `TradeMode`,
`Symbol`, `Terminal`, `TerminalBuild`, `FirstSeenUTC`, `LastSeenUTC`,
`LastResult`, `FloatingProfit`, `Credit`, `Margin`, `FreeMargin`,
`MarginLevel`, `OpenPositions`, `PendingOrders` và `HistorySync`.

- `Account` và `Active` là bắt buộc.
- `Name`, `ExpiryUTC`, `AllowedServer`, `Product` là tùy chọn.
- Để `ExpiryUTC` trống hoặc nhập `0` nếu không hết hạn.
- Để `AllowedServer`/`Product` trống hoặc nhập `*` để cho phép mọi giá trị.
- Các trạng thái hợp lệ: `ACTIVE`, `ENABLED`, `TRUE`, `YES`, `1`, `OK`.
- Tài khoản MT5 chưa có trong bảng sẽ tự được thêm với `Active = FALSE`.

## 2. Triển khai Apps Script

1. Trong Google Sheet, mở **Extensions → Apps Script**.
2. Dán nội dung file `GoogleSheetLicense.gs`.
3. Chạy hàm `setupLicenseSheet()` một lần và cấp quyền khi Google yêu cầu. Hàm này chuẩn hóa `Licenses`, tạo `TradeHistory`/`DailyProfit` và đặt Dashboard rộng gấp 2 lần.
4. Chọn **Deploy → New deployment → Web app**.
5. Chọn **Execute as: Me** và **Who has access: Anyone**.
6. Sao chép URL kết thúc bằng `/exec`.

Sau khi cập nhật mã Apps Script đã triển khai trước đó, vào **Deploy → Manage
deployments → Edit → New version → Deploy**. URL `/exec` cũ được giữ nguyên.

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
- EA đồng bộ toàn bộ deal mà terminal MT5 cung cấp, gồm lệnh mua/bán, nạp/rút,
  credit, phí, commission và các điều chỉnh khác. Lịch sử được gửi theo từng lô
  50 deal, chống trùng bằng cặp `Account + DealTicket`.
- Khi còn dữ liệu cũ, EA gửi tiếp một lô khoảng mỗi 5 giây. Lịch sử rất dài có
  thể cần một lúc để hoàn tất. `HistorySync = COMPLETE` nghĩa là đã bắt kịp lịch
  sử hiện có; sau đó EA kiểm tra deal mới mỗi 60 giây.
- Tab `Dashboard` cho phép chọn `Account` từ danh sách thả xuống rồi tự hiển thị
  Name, trạng thái, broker/server, Balance, Equity, lãi/lỗ thả nổi, lãi/lỗ hôm
  nay, tổng lãi/lỗ, Margin, Free Margin, Margin Level, số vị thế/lệnh chờ và toàn
  bộ lịch sử deal của tài khoản đó. Dashboard giữ bố cục dọc 4 cột và ô `Details`
  nhiều dòng, nhưng tổng bề rộng A:D đã tăng đúng gấp 2 lần, từ 381 px lên 762 px.
- `Today P/L` và `Total P/L` chỉ cộng deal `BUY`/`SELL`, nên nạp/rút tiền không
  bị tính nhầm thành lợi nhuận. Các deal nạp/rút vẫn xuất hiện đầy đủ trong bảng
  lịch sử.
- Tab `DailyProfit` tự nhóm `Net P/L` theo `Date UTC` và `Account`. Chỉ deal
  `BUY`/`SELL` được cộng nên nạp/rút không làm sai lợi nhuận. Công thức dùng toàn
  bộ cột và Apps Script tự tăng số hàng theo `TradeHistory`, không có giới hạn
  ngày hoặc số dòng cố định.
- Tab `TradeHistory` là dữ liệu nguồn cho Dashboard và DailyProfit; có thể ẩn tab
  này để giao diện gọn hơn mà không ảnh hưởng đồng bộ.
- Phần kiểm tra/kích hoạt Google Sheet chạy im lặng, không ghi log duyệt, chờ
  duyệt, mất mạng hay bị từ chối vào Journal/Experts. Chỉ lỗi thật sự khi đóng
  vị thế hoặc xóa pending trong quá trình thu hồi quyền vẫn được ghi lại.
- Lỗi mạng tạm thời dùng kết quả hợp lệ gần nhất tối đa 3 giờ trong phiên chạy hiện tại.
- Khi tài khoản bị tắt hoặc hết hạn, EA xóa pending, đóng vị thế mang Magic
  Number của Gold Reaper rồi tự gỡ khỏi biểu đồ. Lệnh tay và lệnh của EA khác
  không bị tác động.
- Strategy Tester tự bỏ qua xác thực vì MetaTrader không hỗ trợ `WebRequest` trong Tester.

EA cũng đọc được Google Sheet CSV đã publish nếu URL CSV được đặt trực tiếp vào `GR_LICENSE_WEB_APP_URL`; khi đó phải cho phép thêm `https://docs.google.com` trong WebRequest. Cách CSV làm lộ toàn bộ danh sách, vì vậy Apps Script là lựa chọn nên dùng.
