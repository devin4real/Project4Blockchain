# Hướng dẫn Chức năng & Kiểm thử Hệ thống DEX (StanDex - CS251 Proj4)

Tài liệu này mô tả đầy đủ các chức năng đã triển khai cho sàn giao dịch phi tập trung **StanDex** (cặp giao dịch **ETH / STC**) cùng hướng dẫn chi tiết từng bước cài đặt, chạy hệ thống và kiểm thử từng trường nhập, nút bấm trên giao diện web.

---

## 1. Kiến trúc và Chức năng của Hệ thống

Hệ thống gồm 3 thành phần chính:

### 1.1. Token Smart Contract ([`contracts/token.sol`](contracts/token.sol))
- Triển khai chuẩn **ERC-20** (kế thừa `ERC20` và `Ownable` của OpenZeppelin).
- Tên token: **`StanCoin`**, ký hiệu: **`STC`** (đơn vị nguyên, không dùng 18 số thập phân giống cách `init()` trong starter code thiết kế với `total_supply = 100000`).
- **`mint(uint amount)`**: Chỉ `owner` (Account #0) mới gọi được để tạo thêm token, đồng thời tự động thất bại (`Minting has been disabled`) nếu `disable_mint()` đã được gọi.
- **`disable_mint()`**: Chỉ `owner` gọi được, khóa vĩnh viễn chức năng `mint()` về sau.

### 1.2. Exchange Smart Contract ([`contracts/exchange.sol`](contracts/exchange.sol))
Sàn DEX theo mô hình **Automated Market Maker (AMM) Constant Product** ($x \cdot y = k$, tương tự Uniswap V1) cho cặp **ETH / STC**:
- **Khởi tạo bể thanh khoản (`createPool`)**: Account #0 nạp `5000 ETH` và `5000 STC` để thiết lập tỷ giá ban đầu `1 ETH = 1 STC`, khởi tạo `total_shares = 100000` (`lps[owner] = 100`).
- **Hoán đổi ETH sang Token (`swapETHForTokens`)**:
  - Người dùng gửi ETH qua `msg.value`.
  - Thu phí giao dịch **3%** (`swap_fee_numerator = 3`, `swap_fee_denominator = 100`) từ lượng ETH nạp vào, đưa vào quỹ phí riêng `eth_fee_reserves` (không gộp vào `eth_reserves` nên không làm méo tỷ giá AMM).
  - Phần `97% ETH` còn lại được dùng để tính lượng `STC` trả ra theo công thức bảo toàn tích số $x \cdot y = k$.
  - Kiểm tra trượt giá: từ chối nếu giá 1 `STC` tính theo ETH vượt quá `max_exchange_rate`.
  - Đảm bảo pool luôn còn tối thiểu **1 token** và **1 ETH**.
- **Hoán đổi Token sang ETH (`swapTokensForETH`)**:
  - Người dùng phải gọi `approve()` trước trên hợp đồng `Token`, sau đó gửi `amountTokens` vào sàn.
  - Thu phí **3%** bằng `STC`, đưa vào `token_fee_reserves`; phần `97% STC` còn lại dùng để tính lượng `ETH` trả ra.
  - Kiểm tra trượt giá: từ chối nếu giá 1 `ETH` tính theo `STC` vượt quá `max_exchange_rate`.
  - Đảm bảo pool luôn còn tối thiểu **1 ETH** trong bể.
- **Thêm thanh khoản (`addLiquidity`)**:
  - Nhà cung cấp thanh khoản (LP) nạp ETH (`msg.value`) và lượng `STC` tương ứng theo đúng tỷ giá hiện tại để giữ nguyên tỷ giá pool; đồng thời cập nhật `k` và cấp thêm shares (`lps[msg.sender]`, `total_shares`).
  - Kiểm tra trượt giá hai chiều (`min_exchange_rate <= current_rate <= max_exchange_rate`).
- **Rút thanh khoản (`removeLiquidity` và `removeAllLiquidity`)**:
  - Cho phép LP rút một phần thanh khoản (theo lượng `amountETH` muốn rút) hoặc toàn bộ shares đang nắm giữ.
  - Tự động trả cả vốn gốc (`ETH` + `STC`) lẫn **toàn bộ phần thưởng phí giao dịch** tích lũy được, không cần bước claim riêng.
  - Từ chối nếu rút vượt quá shares sở hữu, rút làm cạn pool về `0`, hoặc tỷ giá biến động ngoài `[min_exchange_rate, max_exchange_rate]`.
- **Thưởng phí LP chuẩn Extra Credit (Mục 7.1 trong đề bài)**:
  - Sử dụng bộ tích lũy theo từng share theo thời gian thực với độ phức tạp $O(1)$ (`acc_eth_fee_per_share`, `acc_token_fee_per_share` với `REWARD_PRECISION = 10^24` và `eth_reward_debt` / `token_reward_debt`).
  - Mỗi giao dịch swap chia phí theo đúng tỷ lệ shares của từng LP **tại thời điểm swap diễn ra**.
  - LP mới tham gia pool **không thể rút** phần phí đã thu trước thời điểm họ vào pool.
- **An toàn & Chống tấn công**:
  - Dùng modifier `nonReentrant` và tuân thủ mô hình *Checks-Effects-Interactions*.
  - Kiểm tra chặt chẽ các điều kiện đầu vào qua `require` (chống gửi ETH nhầm vào `removeLiquidity` / `removeAllLiquidity` / `swapTokensForETH`, chống giao dịch 0 đồng, kiểm tra `balanceOf` và `allowance`, làm tròn có lợi cho an toàn pool chống rút cạn bằng lặp nhỏ).

### 1.3. Web Client Backend ([`web_app/exchange.js`](web_app/exchange.js))
- Kết nối tới mạng Hardhat tại `http://localhost:8545`.
- Tự động gọi `init()` trong lần tải trang đầu tiên để `mint` 100.000 `STC`, gọi `disable_mint()`, `approve` và `createPool(5000, 5000 ETH)`.
- Thực hiện `approve` tự động trước khi gọi `addLiquidity` hoặc `swapTokensForETH`, chuyển đổi đơn vị ETH sang WEI qua `ethers.utils.parseEther()`, quy đổi `maxSlippagePct` thành `min_exchange_rate` / `max_exchange_rate` nhân với `10^5`.
- Bắt lỗi và hiển thị thông báo lỗi trực tiếp vào vùng `#log` cuối trang web nếu giao dịch thất bại.

---

## 2. Chuẩn bị và Khởi chạy Hệ thống

> **Lưu ý về môi trường:** Mở 2 cửa sổ Terminal tại thư mục gốc của project (`proj4`). Nếu chưa cài thư viện, chạy `npm install` trước.

### Bước 1: Khởi chạy Local Blockchain Node (Terminal 1)
Tại **Terminal 1**, chạy:
```bash
npx hardhat node
```
- **Kết quả mong đợi:** Terminal hiển thị `Started HTTP and WebSocket JSON-RPC server at http://127.0.0.1:8545/` cùng danh sách 20 tài khoản thử nghiệm (`Account #0` đến `Account #19`, mỗi tài khoản có `10000 ETH`).
- **Giữ nguyên Terminal 1 đang chạy** trong suốt quá trình kiểm thử.

### Bước 2: Triển khai Smart Contracts (Terminal 2)
Tại **Terminal 2**, chạy lần lượt 2 lệnh:
```bash
npx hardhat run --network localhost scripts/deploy_token.js
npx hardhat run --network localhost scripts/deploy_exchange.js
```
- **Kết quả mong đợi:**
  - Lệnh 1 in ra: `Successfully wrote token address 0x5FbDB2315678afecb367f032d93F642f64180aa3 to token_address.txt`
  - Lệnh 2 in ra: `Successfully wrote exchange address 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 to exchange_address.txt`
- *(Lưu ý: Các địa chỉ và ABI của bản compile hiện tại đã được cập nhật sẵn vào [`contracts/exchange.sol`](contracts/exchange.sol) và [`web_app/exchange.js`](web_app/exchange.js). Nếu bạn sửa code Solidity hoặc deploy trên một node đã từng có giao dịch khác làm đổi địa chỉ contract, hãy cập nhật lại `tokenAddr` trong `contracts/exchange.sol`, biên dịch lại, deploy lại và dán địa chỉ + ABI mới vào `web_app/exchange.js`.)*

### Bước 3: Mở Giao diện Web
Mở file [`web_app/index.html`](web_app/index.html) bằng trình duyệt **Google Chrome** (kéo thả file vào Chrome hoặc chạy `open -a "Google Chrome" web_app/index.html`).

> **Lưu ý kỹ thuật:** File `web_app/index.html` gốc của đề bài dùng link CDN cũ `cdn.ethers.io` hiện đã ngừng hoạt động (gây lỗi `ReferenceError: ethers is not defined`, làm trống mục `Current rate:`, `Current Liquidity:` và `My Account`). File `web_app/index.html` đã được cập nhật để nạp `ethers` trực tiếp từ [`node_modules/ethers/dist/ethers.umd.min.js`](node_modules/ethers/dist/ethers.umd.min.js) (kèm dự phòng `cdn.jsdelivr.net`). Lưu ý rằng script nộp bài `make_submit.sh` chỉ đóng gói `contracts/exchange.sol`, `contracts/token.sol`, `DesignDoc.txt` và `web_app/exchange.js`.

---

## 3. Bản đồ Giao diện Web (`web_app/index.html`)

Khi mở trang web, giao diện gồm các khu vực chính sau:
1. **Tiêu đề trang**: Hiển thị `StanDex` / `Decentralized Cryptocurrency Exchange`.
2. **Góc phải (`My Account`)**: Hộp chọn tài khoản (`#myaccount`) gồm 20 địa chỉ Hardhat:
   - `Account #0`: `0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266` *(Chủ pool ban đầu, giữ `95000 STC` sau khi khởi tạo pool)*
   - `Account #1`: `0x70997970c51812dc3a010c7d01b50e0d17dc79c8` *(Ban đầu có `0 STC`, `10000 ETH`)*
   - `Account #2`: `0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc` *(Ban đầu có `0 STC`, `10000 ETH`)*
3. **Thông số thị trường**:
   - **`Current rate:`**: Hiển thị `1 ETH = ... STC` và `1 STC = ... ETH`.
   - **`Current Liquidity:`**: Hiển thị tổng thanh khoản thực trong bể gồm `... ETH` và `... STC` *(không bao gồm quỹ phí LP)*.
4. **Khu vực hoán đổi (`Swap Currencies:`)**:
   - Trường nhập 1 — nhãn **`Amount:`**: Nhập số lượng ETH (nếu bấm Swap ETH for STC) hoặc số nguyên STC (nếu bấm Swap STC for ETH).
   - Trường nhập 2 — nhãn **`Maximum Slippage Percentage:`**: Nhập phần trăm trượt giá tối đa dạng số nguyên (ví dụ `5` nghĩa là `5%`).
   - Nút 1: **`Swap ETH for STC`**
   - Nút 2: **`Swap STC for ETH`**
5. **Khu vực thanh khoản (`Adjust Liquidity:`)**:
   - Trường nhập 1 — nhãn **`Amount in Eth:`**: Nhập số lượng ETH muốn thêm hoặc rút (dùng cho `Add Liquidity` và `Remove Liquidity`).
   - Trường nhập 2 — nhãn **`Maximum Slippage Percentage:`**: Nhập phần trăm trượt giá tối đa (ví dụ `1` nghĩa là `1%`).
   - Nút 1: **`Add Liquidity`**
   - Nút 2: **`Remove Liquidity`**
   - Nút 3: **`Remove All Liquidity`**
6. **Khu vực Log lỗi (dưới cùng trang)**: Hiển thị chi tiết nếu giao dịch bị từ chối hoặc nhập sai định dạng.

---

## 4. Kịch bản Kiểm thử Từng Bước (Step-by-Step Test Cases)

> Thực hiện tuần tự các bước dưới đây trên **một Hardhat node mới khởi động** để đối chiếu đúng từng con số kết quả.

### Kịch bản 1: Kiểm tra Khởi tạo Pool ban đầu
- **Thao tác:** Chỉ cần mở `web_app/index.html` lần đầu và đợi ~1–2 giây (hoặc nhấn F5 nếu trang load lúc node vừa khởi động).
- **Kết quả mong đợi:**
  - Tiêu đề hiển thị: **`StanDex`**
  - **`Current rate:`** hiển thị:
    - `1 ETH = 1 STC`
    - `1 STC = 1 ETH`
  - **`Current Liquidity:`** hiển thị:
    - `5000 ETH`
    - `5000 STC`
  - Tại Terminal 1 (`npx hardhat node`), bạn sẽ thấy các giao dịch `mint`, `disable_mint`, `approve`, `createPool` đã được thực thi thành công.

---

### Kịch bản 2: Đổi ETH sang Token (`Swap ETH for STC`)
Mục tiêu: Kiểm tra Account #1 (chưa có `STC`) đổi `100 ETH` lấy `STC`, có trừ phí 3%.
1. Ở góc phải **`My Account`**, chọn **`0x70997970c51812dc3a010c7d01b50e0d17dc79c8`** (Account #1).
2. Tại khu vực **`Swap Currencies:`**:
   - Nhập vào trường **`Amount:`**: `100`
   - Nhập vào trường **`Maximum Slippage Percentage:`**: `5`
3. Click nút **`Swap ETH for STC`**.
- **Kết quả mong đợi:**
  - Trang tự động tải lại sau khi giao dịch hoàn tất.
  - Phí 3% = `3 ETH` được tách riêng vào quỹ phí; `97 ETH` đi vào pool; lượng token nhận được = $\lfloor 5000 \times 97 / 5097 \rfloor = \mathbf{95\ STC}$.
  - **`Current Liquidity:`** cập nhật thành:
    - `5097 ETH`
    - `4905 STC`
  - **`Current rate:`** cập nhật thành:
    - `1 ETH = 0.9623307828134197 STC`
    - `1 STC = 1.03914373088685 ETH`
  - Account #1 hiện sở hữu **`95 STC`**.

---

### Kịch bản 3: Đổi Token sang ETH (`Swap STC for ETH`)
Mục tiêu: Account #1 dùng `50 STC` vừa có để đổi ngược lại `ETH`.
1. Ở **`My Account`**, giữ nguyên **`0x70997970c51812dc3a010c7d01b50e0d17dc79c8`** (Account #1).
2. Tại khu vực **`Swap Currencies:`**:
   - Nhập vào trường **`Amount:`**: `50`
   - Nhập vào trường **`Maximum Slippage Percentage:`**: `5`
3. Click nút **`Swap STC for ETH`**.
- **Kết quả mong đợi:**
  - Trang tự động tải lại (hệ thống tự gọi `approve(50)` rồi `swapTokensForETH(50)`).
  - Phí 3% = $\lfloor 50 \times 3 / 100 \rfloor = 1\ STC$ vào quỹ phí; `49 STC` đi vào pool; lượng ETH trả về $\approx 50.4144\ ETH$.
  - **`Current Liquidity:`** cập nhật thành:
    - `5046.585587404118 ETH`
    - `4954 STC`
  - **`Current rate:`** cập nhật thành:
    - `1 ETH = 0.9816538160701753 STC`
    - `1 STC = 1.018689056803415 ETH`
  - Account #1 còn **`45 STC`**.

---

### Kịch bản 4: Thêm Thanh khoản (`Add Liquidity`)
Mục tiêu: Kiểm tra thêm thanh khoản theo đúng tỷ lệ pool và đảm bảo tỷ giá không bị bẻ cong.
1. Ở **`My Account`**, chọn **`0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266`** (Account #0, đang có `95000 STC`).
2. Tại khu vực **`Adjust Liquidity:`**:
   - Nhập vào trường **`Amount in Eth:`**: `100`
   - Nhập vào trường **`Maximum Slippage Percentage:`**: `1`
3. Click nút **`Add Liquidity`**.
- **Kết quả mong đợi:**
  - Trang tự động tải lại (hệ thống tự `approve` lượng `STC` cần thiết và nạp `100 ETH` + `99 STC` theo tỷ lệ pool).
  - **`Current Liquidity:`** tăng lên:
    - `5146.585587404118 ETH`
    - `5053 STC`
  - **`Current rate:`** gần như không đổi (`1 ETH = 0.9818159854111507 STC`, `1 STC = 1.0185207970322814 ETH`).
  - Account #0 bị trừ `99 STC` (còn `94901 STC`) và nhận thêm `2081` shares (tổng shares của Account #0 là `2181 / 101981`, gồm `100` shares khởi tạo + `2081` shares vừa thêm).

---

### Kịch bản 5: Tích lũy Phí giao dịch & Rút một phần Thanh khoản (`Remove Liquidity`)
Mục tiêu: Thực hiện swap tạo phí để kiểm chứng LP nhận được cả gốc lẫn phần thưởng phí khi gọi `Remove Liquidity`.
1. Ở **`My Account`**, giữ **`0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266`** (Account #0).
2. Tại khu vực **`Swap Currencies:`** — giao dịch tạo phí ETH:
   - Nhập vào **`Amount:`**: `1000`
   - Nhập vào **`Maximum Slippage Percentage:`**: `5`
   - Click nút **`Swap ETH for STC`**.
   - Chờ trang tải lại (`Current Liquidity:` đổi thành `6116.585587404118 ETH` và `4252 STC`, quỹ phí tích lũy thêm `30 ETH`).
3. Tiếp tục tại khu vực **`Swap Currencies:`** — giao dịch tạo phí STC:
   - Nhập vào **`Amount:`**: `2000`
   - Nhập vào **`Maximum Slippage Percentage:`**: `5`
   - Click nút **`Swap STC for ETH`**.
   - Chờ trang tải lại (`Current Liquidity:` đổi thành `4200.213487991329 ETH` và `6192 STC`, quỹ phí tích lũy thêm `60 STC`).
4. Bây giờ tại khu vực **`Adjust Liquidity:`** — rút một phần thanh khoản:
   - Nhập vào trường **`Amount in Eth:`**: `50`
   - Nhập vào trường **`Maximum Slippage Percentage:`**: `1`
   - Click nút **`Remove Liquidity`**.
- **Kết quả mong đợi:**
  - Trang tự động tải lại.
  - **`Current Liquidity:`** giảm đúng phần vốn gốc rút ra:
    - `4150.213487991329 ETH` (giảm đúng `50 ETH`)
    - `6119 STC` (giảm `73 STC`)
  - **`Current rate:`** giữ ổn định:
    - `1 ETH = 1.4743819848558075 STC`
    - `1 STC = 0.6782502840319218 ETH`
  - **Phần thưởng phí LP (Extra Credit):** Ngoài `50 ETH` và `73 STC` gốc, Account #0 nhận thêm toàn bộ thưởng phí tích lũy được trong thời gian nắm giữ shares (~`0.61517 ETH` và `1 STC` từ quỹ phí, nâng số dư token của Account #0 từ `93702` lên `93776 STC`).

---

### Kịch bản 6: Rút toàn bộ Thanh khoản còn lại (`Remove All Liquidity`)
Mục tiêu: Kiểm tra nút `Remove All Liquidity` rút hết toàn bộ shares còn lại của tài khoản đang chọn.
1. Ở **`My Account`**, giữ **`0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266`** (Account #0).
2. Tại khu vực **`Adjust Liquidity:`**:
   - Trường **`Amount in Eth:`**: Để trống (không dùng cho nút này).
   - Nhập vào trường **`Maximum Slippage Percentage:`**: `1`
3. Click nút **`Remove All Liquidity`**.
- **Kết quả mong đợi:**
  - Trang tự động tải lại.
  - Toàn bộ shares còn lại của Account #0 được rút hết, `lps[Account #0]` về `0`.
  - **`Current Liquidity:`** cập nhật thành:
    - `4114.5050209923265 ETH`
    - `6067 STC`
  - **`Current rate:`** vẫn giữ ổn định (`1 ETH = 1.4745394571269173 STC`).
  - Account #0 tăng thêm `52 STC` (lên `93828 STC`).

---

### Kịch bản 7: Kiểm thử các Trường hợp Lỗi & Bảo vệ (Negative Tests)

Với tất cả các kịch bản lỗi dưới đây, **trang web sẽ KHÔNG tải lại**, mà giữ nguyên trạng thái và in thông báo lỗi vào khung log ở dưới cùng trang (và trong DevTools Console):

1. **7a. Swap Token khi ví không có đủ Token:**
   - Chọn **`0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc`** (Account #2, có `0 STC`) trong `My Account`.
   - Tại **`Swap Currencies:`**: nhập **`Amount:`** = `10`, **`Maximum Slippage Percentage:`** = `1`.
   - Click **`Swap STC for ETH`**.
   - **Kết quả mong đợi:** Khung log ở cuối trang hiển thị `"Transaction Error": "... Insufficient token balance ..."`.

2. **7b. Nhập số Token dạng số thập phân (không hợp lệ):**
   - Chọn Account #1 hoặc #0.
   - Tại **`Swap Currencies:`**: nhập **`Amount:`** = `10.5`, **`Maximum Slippage Percentage:`** = `1`.
   - Click **`Swap STC for ETH`**.
   - **Kết quả mong đợi:** Khung log hiển thị `"Transaction Error": "Invalid token amount: must be a positive integer."`.

3. **7c. Rút thanh khoản khi chưa từng cung cấp thanh khoản:**
   - Chọn **`0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc`** (Account #2, có `0` LP shares) trong `My Account`.
   - Tại **`Adjust Liquidity:`**: nhập **`Amount in Eth:`** = `10`, **`Maximum Slippage Percentage:`** = `1`.
   - Click **`Remove Liquidity`**.
   - **Kết quả mong đợi:** Khung log hiển thị `"Transaction Error": "... No liquidity provided ..."`.

4. **7d. Rút thanh khoản vượt quá phần sở hữu:**
   - Chọn **Account #0** (`0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266`), tại **`Adjust Liquidity:`**, nhập **`Amount in Eth:`** = `10`, **`Maximum Slippage Percentage:`** = `1`, click **`Add Liquidity`** (nạp `10 ETH` và `15 STC`).
   - Sau khi trang tải lại, giữ nguyên **Account #0**, nhập **`Amount in Eth:`** = `500`, **`Maximum Slippage Percentage:`** = `1`, click **`Remove Liquidity`**.
   - **Kết quả mong đợi:** Khung log hiển thị `"Transaction Error": "... Insufficient liquidity shares ..."`.

5. **7e. Kiểm thử Bảo vệ Trượt giá (Slippage Protection) bằng 2 tab trình duyệt:**
   - Mở `web_app/index.html` trên **2 tab Chrome song song** (Tab A và Tab B) khi pool đang ổn định.
   - Tại **Tab A**: nhập `500` vào `Amount:` và `1` vào `Maximum Slippage Percentage:`, **nhưng chưa bấm**; hoặc tại **Tab B** trước đó bạn thực hiện trước một giao dịch **`Swap ETH for STC`** với `Amount:` = `1000`, `Maximum Slippage Percentage:` = `5` để làm tỷ giá thay đổi mạnh (>1%).
   - *(Cách mô phỏng chuẩn nhất qua Console trên một tab:)* Mở DevTools Console (`Cmd + Option + J` trên Mac / `F12` trên Windows) và chạy lệnh gọi contract trực tiếp với `max_exchange_rate` thấp hơn tỷ giá hiện tại, ví dụ:
     ```js
     await exchange_contract.connect(provider.getSigner(defaultAccount)).swapETHForTokens(1, { value: ethers.utils.parseEther("10") })
     ```
   - **Kết quả mong đợi:** Giao dịch bị từ chối ngay trên blockchain với lỗi `"Slippage limit exceeded"`.

---

## 5. Kiểm thử Tự động (Automated Tests & Sanity Check)

### 5.1. Chạy Sanity Check trong trình duyệt (Lưu ý Mục 10 đề bài)
1. Mở DevTools Console trong Chrome (`Cmd + Option + J` trên Mac hoặc `Ctrl + Shift + J` trên Windows/Linux).
2. Gõ lệnh:
   ```js
   await sanityCheck()
   ```
   *(Lưu ý: `setTimeout` tự chạy `sanityCheck()` sau 10 giây đã được tạm comment ở cuối `web_app/exchange.js` để không làm xáo trộn số liệu khi bạn kiểm thử thủ công từng bước trên UI.)*
3. **Cách đọc kết quả `sanityCheck()`:**
   - `Test adding liquidity: SUCCESS`
   - `Test removing liquidity: SUCCESS`
   - `Test removing all liquidity: SUCCESS`
   - Lưu ý: Hai dòng kiểm tra đầu (`Testing simple exchange of ETH to token` và `Test simple exchange of token to ETH`) trong code mẫu của khóa học có assertion `=== 100` và `=== state1.token_liquidity + 90` (bị copy từ phần chưa có phí 3% — thực tế `eth_reserves` chỉ tăng `97` ETH và `token_reserves` chỉ tăng `88` STC do `3%` phí đã được tách riêng vào `eth_fee_reserves`/`token_fee_reserves` theo đúng Yêu cầu #3 Mục 7). Chính Mục 10 của `proj4.pdf` cũng đã lưu ý không dựa máy móc vào `sanityCheck()`.

### 5.2. Kiểm tra số liệu trực tiếp bằng Console của Trình duyệt
Bất kỳ lúc nào khi đang mở `web_app/index.html`, bạn có thể mở DevTools Console và kiểm tra chi tiết trạng thái on-chain của tài khoản đang chọn:
```js
// Xem số dư token STC của tài khoản đang chọn
(await token_contract.balanceOf(defaultAccount)).toString()

// Xem số lượng LP shares đang sở hữu / tổng shares toàn pool
(await exchange_contract.getLPShares(defaultAccount)).map(x => x.toString())

// Xem quỹ phí ETH và STC đang tích lũy trong sàn
(await exchange_contract.getFeeReserves()).map(x => x.toString())

// Xem phần thưởng phí LP hiện tại có thể rút của tài khoản đang chọn
(await exchange_contract.getPendingRewards(defaultAccount)).map(x => x.toString())
```
