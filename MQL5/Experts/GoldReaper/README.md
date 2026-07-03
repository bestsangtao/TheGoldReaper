# The Gold Reaper - ban chuyen doi MQL5

Thu muc nay chua ban MQL5 duoc chuyen doi tu ban goc MQL4
(`MQL4/GoldReaper/GoldReaper_v4.1.mq4`), giu nguyen 100% logic giao dich.

## Cai dat

1. Copy `MQL5/Include/GoldReaper/MQL4Compat.mqh` vao
   `<Thu muc du lieu MT5>/MQL5/Include/GoldReaper/MQL4Compat.mqh`
2. Copy `MQL5/Experts/GoldReaper/GoldReaper_v4.1.mq5` vao
   `<Thu muc du lieu MT5>/MQL5/Experts/GoldReaper/GoldReaper_v4.1.mq5`
3. Mo MetaEditor, bien dich lai `GoldReaper_v4.1.mq5` (F7).

## YEU CAU BAT BUOC: tai khoan Hedging

EA nay co the mo **dong thoi nhieu lenh/vi the tren cung 1 symbol**
voi cac magic number khac nhau (nhieu strategy chay song song, zone
recovery, lenh cho BuyStop/SellStop...). Day la mo hinh giao dich cua
MQL4, chi tuong thich voi tai khoan MT5 o che do **Hedging**.

Neu chay tren tai khoan **Netting**, MT5 se gop tat ca lenh cung
symbol thanh **1 vi the duy nhat**, pha vo hoan toan logic quan ly
lenh cua EA (dem lenh, dong tung lenh theo magic, trailing tung lenh
rieng le...). Hay kiem tra loai tai khoan truoc khi chay EA (Cong cu >
Tuy chon, hoac hoi broker khi mo tai khoan demo/live).

## Nhung gi da duoc chuyen doi

Xem chi tiet trong `MQL5/Include/GoldReaper/MQL4Compat.mqh` (comment
dau file). Tom tat:

- `OrderSend/OrderModify/OrderClose/OrderDelete/OrderSelect`,
  `OrdersTotal()` (doi ten thanh `MT4OrdersTotal()` de tranh trung ten
  voi ham co san cua MQL5), `HistoryTotal()`, va toan bo
  `OrderTicket/OrderType/OrderLots/OrderOpenPrice/.../OrderComment` ->
  anh xa sang Position/Order/History deal cua MQL5.
- Vao/sua/dong/huy lenh (`OrderSend/OrderModify/OrderClose/OrderDelete`
  kieu MQL4) duoc thuc thi bang `OrderSendAsync()` (gui lenh khong
  dong bo) thay vi `CTrade` (dong bo, cho MetaQuotes xu ly xong moi
  tra ve) de giam do tre khi vao/thoat lenh. Sau khi goi
  `OrderSendAsync()`, EA cho ket qua thuc te tra ve qua su kien
  `OnTradeTransaction()` (khop bang `request_id`, timeout toi da 5
  giay) roi moi tra ket qua ve cho code goc - vi vay ham
  `OrderSend/OrderModify/OrderClose/OrderDelete` van tra ve ticket/
  ket qua ngay lap tuc y het ban CTrade truoc day, khong can sua bat
  ky dong code nao khac trong `GoldReaper_v4.1.mq5`. Filling-mode
  (FOK/IOC/RETURN) duoc tu chon bang `SYMBOL_FILLING_MODE` (uu tien
  FOK > IOC > RETURN, giong logic CTrade dung truoc day).
- `MarketInfo()`, `AccountBalance()/AccountEquity()/AccountCurrency()`,
  `AccountFreeMarginCheck()` -> `SymbolInfo*`/`AccountInfo*`.
- `Year()/Month()/Day()/Hour()/Minute()/Seconds()/DayOfWeek()` va cac
  ban `TimeXxx(datetime)` tuong ung -> `TimeToStruct()`.
- `iMA()/iFractals()` kieu MQL4 (tra ve gia tri truc tiep) -> handle +
  `CopyBuffer()` cua MQL5.
- Timeframe kieu "so phut" cu cua MQL4 (`60`=H1, `1440`=D1...) duoc
  quy doi qua `MT4Period()` truoc khi goi cac ham
  `iHigh/iLow/iOpen/iClose/iTime/iVolume/iBars/iBarShift/iHighest/iLowest`
  (cac ham nay van ton tai truc tiep trong MQL5 nhung dung
  `ENUM_TIMEFRAMES`, khac gia tri so voi MQL4).
- `extern` (bien input) -> `input` (bat buoc trong MQL5, `extern`
  trong MQL5 mang y nghia khac va khong the co gia tri khoi tao).
- `init()/deinit()` -> `OnInit()/OnDeinit()` (su kien `OnTick()` giu
  nguyen vi ban .mq4 goc da dung dang su kien moi nay san).
- `GetLastError()` ngay sau cac lenh giao dich -> `MT4_LastError()`
  (tra ve ma loi kieu MQL4, vi MQL5 tra loi lenh giao dich qua
  `MqlTradeResult.retcode` chu khong qua `GetLastError()`).

## Gioi han da biet

- Vong lap doc lich su lenh (`pool=MODE_HISTORY`) gop cac deal dong 1
  phan cua cung 1 vi the thanh 1 ban ghi (EA nay khong dung dong 1
  phan lenh nen khong bi anh huong trong thuc te).
- Ma loi giao dich duoc quy doi gan dung tu `retcode` cua MQL5 ve ma
  loi MQL4 tuong ung (dung cho cac so sanh nhu `==132` trong code goc);
  khong phai anh xa 1-1 tuyet doi cho MOI ma loi hiem gap.
- Neu sau khi goi `OrderSendAsync()` ma khong nhan duoc phan hoi tu
  `OnTradeTransaction()` trong vong 5 giay (mat ket noi server, treo
  terminal...), ham `OrderSend/OrderModify/OrderClose/OrderDelete` se
  tra ve that bai (`-1`/`false`) du lenh co the van duoc xu ly o phia
  server sau do - day la danh doi de tranh treo EA vo thoi han cho.

## Khuyen nghi truoc khi chay tien that

Luon backtest/forward-test tren tai khoan demo (Hedging) truoc khi
dua EA nay vao tai khoan that, dac biet sau khi chuyen doi ngon ngu.
