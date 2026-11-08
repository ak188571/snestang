# UART8 SDRAM連続格納 2026年11月8日

UARTを8 Mbit/s、DATAを最大1024 byte、windowを2のまま保ち、SNES sinkの格納を連続化した。本節の設計・模型の評価後に実機へ適用し、同じcoreを用いたCPU重ね合わせ版の通常起動も確認した。到達点は末尾に記録する。

## 待ち時間の調査

公開基準のsinkをConsole138Kの実controller `sdram_cl2_2ch.v` と接続した。SDRAMのcommandを受ける模型で全wordのaddress・data・書込み数、ENDの実メモリ読戻しを照合した。同期payload RAM、fclk:mclk=3:1、mclk=2000/93 MHz、同一clock位相、SD/CPUなしの試験である。電気的なSDRAM timing模型ではない。

従来は1 wordでFETCH/FETCH_WAITが4、CONSUMEが2、WRITE_ACKが3、WRITE_DRAINが5、計14 mclk。ACK同期を含む値であり、別に同期2 clockを加算しない。新sinkは8 byteのqueueと1 wordの組立てを並行し、通常の連続wordではACK待ち3 mclkに重なる。DATA境界の準備・最終回復待ちは別に残る。

| ROM本体 | 旧格納 ms | 新格納 ms | 短縮率 | END ms 変更前後同一 |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 21.356 | 4.622 | 78.36% | 13.714 |
| 2048 KiB | 683.108 | 147.804 | 78.36% | 438.829 |
| 4096 KiB | 1366.207 | 295.604 | 78.36% | 877.658 |

格納単体の合計はdescriptorの同期・完了も含む。UART・SD・firmware実行は含まない。実機の3.237535/6.467952秒やENDの0.487760/0.975412秒へこの短縮率を直接適用しない。実機はACK位相・CPU・SD・frame処理が加わり、今回の模型のEND時間とも一致しない。

実bit周期UART試験は同じ64 KiBで、window=2のDATAからACK完了が 84.363 → 84.085 ms、0.33%短縮。UART RTLと共通C++/RTLを用い、memoryは従来の振る舞い模型。SD・実CPU・FPGA書換え・END・ゲーム起動を含まない。

この小さい改善幅は格納を既にUART受信と重ねているためである。引継ぎの実機値に対し、DATA線路時間の下限は2 MiBで2.682990秒、4 MiBで5.365870秒（8N1、payloadと各24 byteの付加情報、header別DATAを含む）。実機区間との差は0.554545／1.102082秒。ただし速度切替などの制御・CPU/frame CRC・SDの重ならない待ち・ACKなどの合計差で、今回これらを個別に測ったものではない。SD読み出しの累積0.198536／0.417968秒をこの差へ単純加算しない。sinkの改善率をこの差へ直接適用することもできない。

## 実装と完了条件

`tc_snes_rom_sink.sv`だけが実行時の変更。同期RAMの未回収readをqueue占有へ加え、8 byteを超える先読みを発行しない。bankとdescriptorはdoneまで保持する。受信済みpayloadは従来どおりframe CRCを通ってからsinkへ渡る。

controllerはaddress/dataをcaptureした後にACKを返し、次のrequestを許可する。ACKを2段同期してから次wordを要求し、controller自体のcommand scheduleやSDRAMの回復条件は変更しない。次wordがないときは固定の回復待ちへ入り、DATA ACKは最後のwordのACKと回復待ちの後だけ返す。header/奇数末尾byteだけの場合も既存の部分word保持を守る。

session、sequence、offset、CRC-32/ISO-HDLC、完全一致の2件再送履歴、最大4回、window=2、FIFO、START条件、異常時のreset保持は共通処理のまま。ENDのstateと読戻し範囲・CRC式は変更していない。実SDRAMの全ROMと64 byte headerのCRC一致後だけSTARTを許可する。

## UART上限とSPI

BL616/BL618 DatasheetのUART節は最大10 Mbit/sを明記する。[製造元source](https://raw.githubusercontent.com/bouffalolab/bl_docs/main/BL616_DS/en/RST/Functional.rst)。引継ぎの16 Mbit/s案は仕様上限外として採用しない。今回の設定は8 Mbit/s、通常制御は2 Mbit/s。10 Mbit/sへの変更・実機保証は行っていない。

共通Session/receiverへUARTのDMA・pin・baudやSPIのCSを持ち込んでいない。改善はcore側sinkの後段に置き、どちらのtransportも同じ格納経路を使える。LINK_CONTROL=0でも共通C++/RTL試験を通過した。SPIの物理adapterは未実装。

## 検証

- 共通C++ Sessionと実RTLで2/4 MiB、CRC破損、ACK消失/破損、2件の再送、異なるpayload、65 byte分割、SDRAM停止/読戻し破損/FIFO超過を確認。
- 実controllerで1/2/3/7/63/64/65/127/1023/1024 byte分割とACK追加遅延0/1/7/15 mclkの40条件。各DATA ACK時のheader数・物理書込み数も確認。
- 実bit周期の2→8→2 Mbit/s、連続8N1、±2%、DATA/END ACK消失、実timeout、watchdog。
- UART固有制御を外した同一共通Session/RTL。
- Gowin 1.9.12.03全build。setup/hold違反 0/0、Fmax 80 MHz系 86.214 MHz、96 MHz系 96.085 MHz。96 MHz系の余裕は 0.085 MHzと小さい。制約とPLLは公開基準のまま。既存PLL警告とsys_clk_dのgeneric routing警告を保持した解析で、電源・温度・配線条件を広げた実機検証は未実施。source全件hashとbuild中の不変を照合。

基準SNES commit `d4d46357a226ce77b08b78cf4be938fc6111bb80`、firmware `6744940d6a1a84f677c9bd4e73696788bf3fb1de`、共通tag `uart8-overlap-hw-20261108`。作業branch `uart8-continuous-20261108`。当初の検証時点ではcommit/push前だった。

実機へ適用後、SDRAM連続格納だけでは転送時間は短縮しなかった。CPU処理・CRC計算・ACK処理の計測と重ね合わせを続け、以下の通常版で起動・下段表示・一覧復帰まで確認した。通常版と計測版を配布物で区別し、全flash・ゲームROMは配布しない。

## 通常版の実機確認・公開（2026年11月8日）

共通tag `uart8-cpu-overlap-hw-20261108`、統合先 `tangcore-integrated`。
軽量計測と詳細計測をともにOFFにした通常版を適用し、BOOT再接続後の独立した全flash読戻しで
firmwareと対象外領域の一致を確認した。利用者は2 MiB・4 MiBの2本とも
起動・下段の準備／転送／照合表示・一覧復帰を正常と確認した。
通常版の転送時間・タイトル到達時間は再計時していない。

- 通常版firmware: 241472 byte、SHA-256 `fa0e48157191afb19be3ac7ecfbaf4ffd0d00cefcda9bf6294b6f5700c4ec0eb`。
- 通常版全flash SHA-256: `7b0e1a58807062ae3e786cefe11da94395fefdda8f3a81538bce35f29ba432f5`。
- SNES core: 4767636 byte、SHA-256 `ca489a5fe2696716d58dc968854ed1bfb75d67b37365b68b5c3f1f88e218e191`。通常版切替時に変更なし。
- 切替前のmicroSD 91 user filesを保存・照合し、実行後も全ファイルの内容・属性・mtimeが一致。sector imageではない。
- 軽量計測版での改善: 2 MiB 3.286302→2.723655秒（17.12%）、4 MiB 6.564648→5.432306秒（17.25%）。各条件1回。
- ENDは0.487768／0.975417秒、CRCはc287a01c／21e24729、再送は両方0回。
- SPIの共用C++／RTLは検証済み、物理SPIは未実装。

親repositoryの `docs/rom/UART8_CPU_OVERLAP_20261108.md` と
`verification/uart8-cpu-overlap-20261108/` に配布物・対応commit・確認結果を記録する。
flash全体・SDコピー・ゲームROMは公開物へ含めない。
