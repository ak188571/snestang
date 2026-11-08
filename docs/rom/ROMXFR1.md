# Console138KのUART 8 Mbit/sとロード進捗

2026年11月8日の実機確認済み到達点をtag `uart8-progress-hw-20261108` で記録する。
firmware-bl616の共通ROMXFR1処理と組み合わせ、DATAのCRC、格納完了後のACK、重複DATAの判定、ENDでのSDRAM全体の読み戻し照合を行う。

UARTは80 MHzのclockから2 Mbit/sと8 Mbit/sを生成する。
進捗は格納完了済みのROM本体から計算し、5%刻みで、既存の黄色い8×8文字を列1・行27に表示する。
表示状態はHDMI側のフレーム境界で反映する。
タイミングを満たすため、ROMの次の連番をbyte単位で先に計算し、USB descriptorの先頭部と本文の保存を分離した。

`gw_sh build_console138k_usb.tcl console138k ds2` でGowin 1.9.12.03を用いて生成した。
採用結果はsetup違反0件・hold違反0件、96 MHz系のFmax 96.325 MHz、80 MHz系のFmax 81.127 MHz。
SD用binは4878740 byte、SHA-256は `e3b9565a05791420073f20d6d8ebd0b8d40b42eddfc05e04f4cdf6340540613f`。
対応する通常版firmwareのSHA-256は `1f1bdb2455e99210b420a9e94bd20b2565db7506c1f79deb086fba87733403f2`。

2 MiB・4 MiBの転送と照合、再送・破損時の処理をPCで試験した。
実機ではマリオコレクションとドンキーコングの転送・照合、および最終版の下段表示・起動を確認した。
計測用firmwareで記録した最終マリオの転送は3.989秒、読み戻し照合は0.488秒、再送0回。
通常版での起動とロード中の表示も利用者が確認した。

親repositoryの `verification/uart8-progress-20261108/` と `docs/rom/UART8_PROGRESS_20261108.md` に成果物と実機確認範囲を記録する。
